# v2 architecture

A Quickshell shell for Hyprland. A small fixed core owns the process, the compositor connection, the theme tokens, the surface hosts, the plugin loader and the plugin manager. Everything a user sees or a service does is a plugin, and every plugin carries the check that proves it stays inside its latency and memory budget.

## The one idea

The plugin is the unit of change and the core is the foundation it stands on. The core changes rarely, fits in one agent's context, and names no plugin. A plugin is one directory with one manifest, declares every surface it can fill and every core capability it uses, and is shown on each surface whose host exists. Plugins do not depend on one another. A change that needs a new core capability lands the capability first, with its own validation row, then the plugin that uses it. The plugin manager is part of the core, because it must exist before any plugin does and must keep working when a plugin breaks.

## Vocabulary

- Core: everything under `shell/` except `shell/plugins/`, plus `bin/` and `config/`. The runner, the instance lock, the Hyprland connection and its reply judge, the theme tokens, the hosts, the plugin registry, the plugin manager and the IPC surface.
- Plugin: a directory with `manifest.json` at its root, in the Omarchy Quattro schema, plus one QML entry point per kind.
- Kind: one of `bar-widget`, `bar`, `panel`, `overlay`, `menu`, `service`. A kind is a surface the core can host. The core owns the list; a new kind is a core change.
- Host: a core-owned Wayland surface a plugin draws inside. A plugin creates no surface of its own.
- Bar: the plugin of kind `bar` that is active. It lays out bar widgets in three sections and is the host for kind `bar-widget`.
- Bar widget: a plugin of kind `bar-widget`. It draws one item in a bar section.
- Service: a plugin of kind `service`. No surface. It owns watchers, pollers and subprocesses.
- Capability: a core API a plugin names in its manifest and receives on its scoped `shell` object at load.
- Plugin manager: the core component that discovers, validates, enables and disables plugins, and will install, update and remove them. Its user interface is a plugin; its mechanism is not.
- Budget: a ceiling a validation row asserts in the nested sandbox.
- Validation row: an entry in `scripts/validate`. A plugin without a row does not merge.

## Boundaries

- Core: depends on Quickshell, Qt, the Hyprland socket and `config/shell.json`. Contains no plugin code and no plugin name. Enforced by `scripts/check-plugin-boundary.py`.
- Plugin: depends on `qs.Commons`, `qs.Ui`, the Qt and Quickshell modules other than `Quickshell.Wayland`, the capabilities its manifest names, and its own directory. Enforced by the same check.
- Plugin manager: depends on the core and git. Runs no code from a plugin. Enforced by the manager's rows in `scripts/validate` once install exists.
- Validation: depends on the nested compositor sandbox, built from the repository alone, with its runtime dir beside the host's. Never touches the live session.
- The plugin boundary is a static import check plus a scoped API object. It is not a process sandbox. Read [plugins.md § Isolation](plugins.md#isolation) before relying on it.

## Invariants

1. One shell process per session. The runner holds the lock and the shell draws only when its process is the runner's. Enforced by `scripts/qml-smoke.sh`, which starts a bare `qs` beside the runner and asserts it refuses.
2. Every Wayland object the shell creates is dispatched or destroyed. Enforced by the resident-size ceiling in `scripts/qml-smoke.sh`.
3. A plugin unloads cleanly: after unload no widget, surface or object of it remains. Enforced by the disable rows in `scripts/qml-smoke.sh`.
4. The plugin manager runs no plugin code and asks for no privilege. Enforced by its rows once install exists.
5. An unmodified Omarchy Quattro plugin that uses only what [plugins.md](plugins.md) lists as provided loads without edits. Enforced by the compatibility fixture row once it exists.
6. Every figure in a document was measured in the PR that wrote it, and the document names how.

## Decisions

- Hyprland only. Niri support in the previous shell doubled the compositor code paths and the review surface.
- Quickshell 0.3.1 is the baseline. Every recipe with a version slot requires at least it.
- Everything outside the core is a plugin, and the plugin manager is core.
- The plugin manifest is the Omarchy Quattro `manifest.json`, schema version 1, with v2 additions under one reserved key, so Omarchy plugins load unchanged and first-party plugins publish to the Omarchy marketplace unchanged.
- The six Omarchy kinds are the surface list, and plugins declare no dependencies. [plugins.md](plugins.md) holds the rest.
- The core is privileged and plugins cannot replace it.
- Install runs no plugin code and lands the plugin disabled.
- Each change carries its own validation row.
- The allocator is Quickshell's jemalloc. The shell sets no allocator tuning.

No decision record exists yet. The first structural PR writes them with the decider skill.

## Topics

- [plugins.md](plugins.md): read before writing a plugin, a host, the manager or a compatibility shim.
- [runtime.md](runtime.md): read before touching anything that starts, stops, measures or talks to the shell.
- [memory.md](memory.md): read before attributing memory growth or writing a memory budget.
