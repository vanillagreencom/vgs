# v2 architecture

A Quickshell shell for Hyprland. A small fixed core owns the process, the compositor connection, the theme tokens, the surface hosts, the plugin loader and the plugin manager. Everything a user sees or a service does is a plugin, and every plugin carries the validation row that proves it is built, shown and handed what it asked for. The smoke measures the shell's startup and reconcile latency against budgets; per-plugin latency and memory budgets are a target until a row measures them.

## The one idea

The plugin is the unit of change and the core is the foundation it stands on. The core changes rarely, fits in one agent's context, and names no plugin. A plugin is one directory with one manifest, declares every surface it can fill and every core capability it uses, and is shown on each surface whose host exists. Plugins do not depend on one another. A change that needs a new core capability lands the capability first, with its own validation row, then the plugin that uses it. The plugin manager is part of the core, because it must exist before any plugin does and must keep working when a plugin breaks.

## Vocabulary

- Core: the runner, the instance lock, the Hyprland connection and its reply judge, the theme tokens, the hosts, the plugin registry, the plugin manager and the IPC surface. `scripts/check-plugin-boundary.py` draws the line.
- Plugin: a directory with `manifest.json` at its root, in the schema [plugins.md](plugins.md) states, plus one QML entry point per kind.
- Kind: one of `bar-widget`, `bar`, `panel`, `overlay`, `menu`, `service`, `background`. A kind is a surface the core can host, and every kind has a host. The core owns the list; a new kind is a core change.
- Host: a core-owned Wayland surface a plugin draws inside. A plugin creates no surface of its own.
- Bar: the plugin of kind `bar` that is active. It declares three section containers the core mounts bar widgets into; it owns their geometry and its own built-in widgets.
- Built-in widget: a widget a plugin draws itself inside its own surface, such as the shipped bar's clock. It is part of that plugin, not a plugin; the plugin registers it so the build records list it.
- Bar widget: a plugin of kind `bar-widget`. It draws one item in a bar section.
- Service: a plugin of kind `service`. No surface. It owns watchers, pollers and subprocesses.
- Capability: a core API a plugin names in its manifest and receives on its scoped `shell` object at load. Its provider is made for one instance, and everything the instance registers through it is released when the instance is destroyed.
- Plugin manager: the core component that discovers, validates, enables and disables plugins, and installs, updates and removes them. Its user interface is the shipped bar's manager built-in, reached through the `manager` capability; its mechanism is core.
- Budget: a ceiling a validation row asserts in the nested sandbox.
- Validation row: an assertion in `scripts/qml-smoke.sh` that a plugin is built, shown and handed what it asked for, read back from the instance. A plugin without one does not merge.

## Boundaries

- Core: depends on Quickshell, Qt, the Hyprland socket and `config/shell.json`. Contains no plugin code and no plugin name. Enforced by `scripts/check-plugin-boundary.py`.
- Plugin: depends on the import set [plugins.md § Isolation](plugins.md#isolation) lists, the capabilities its manifest names, and its own directory. Enforced by the same check.
- Plugin manager: depends on the core and git. Runs no code from a plugin. Enforced by the install rows in `scripts/test-vgsh.sh`.
- Validation: depends on the nested compositor sandbox, built from the repository alone, with its runtime dir beside the host's. Never touches the live session.
- The plugin boundary is a static import check plus a scoped API object. It is not a process sandbox. Read [plugins.md § Isolation](plugins.md#isolation) before relying on it.

## Invariants

1. One shell process per session. The runner holds the lock, records its pid, and the shell draws and accepts state changes only when its process is the runner's; the CLI addresses that pid alone. Enforced by `scripts/test-vgsh.sh` (lock contention, argument refusal, pid selection) and `scripts/qml-smoke.sh`, which starts a bare `qs` beside the runner and asserts it neither draws nor writes.
2. Every Wayland object the shell creates is dispatched or destroyed. No check enforces it yet; a long sampled session with `scripts/sample-shell-memory.sh` is the instrument.
3. A disabled plugin leaves the core's build records and the bar, and a disabled bar leaves no surface and reserves no space. Enforced by the disable rows in `scripts/qml-smoke.sh`, which read the compositor's layer list and reserved geometry. That no object of it remains is not checked.
4. A plugin receives exactly the capabilities its own manifest names, a disabled plugin holds none of them, and a running plugin holds the settings the configuration currently gives it. Enforced by the fixture rows in `scripts/qml-smoke.sh`, which read the fixture instances and the core's lending record back.
5. The plugin manager runs no plugin code and asks for no privilege. Enforced by the install rows in `scripts/test-vgsh.sh`, which run every git call with hooks off and install from local repositories.
6. Every decision about a manifest, the merged configuration, enablement and placement is made once in `shell/Core/PluginLogic.js`. Enforced by `scripts/test-plugin-logic.js` and by `scripts/check-manifests.js`, which loads the same file.
7. A figure in a document names the tool and the run that produced it. Enforced by review; `docs/architecture/memory.md` names its provenance in its first paragraph.

## Decisions

- [D001](../decisions/D001-hyprland-only.md): Hyprland only.
- [D002](../decisions/D002-quickshell-0-3-1-baseline.md): Quickshell 0.3.1 is the baseline.
- [D003](../decisions/D003-everything-is-a-plugin.md): everything outside the core is a plugin; the manager is core; the core names no plugin.
- [D004](../decisions/D004-manifest-schema-borrowed-from-another-shell.md): superseded by D011.
- [D005](../decisions/D005-kinds-are-surfaces-no-dependencies.md): kinds are surfaces; plugins declare no dependencies.
- [D006](../decisions/D006-two-configuration-layers.md): two configuration layers merged by entry id.
- [D007](../decisions/D007-install-runs-no-plugin-code.md): install runs no plugin code and lands the plugin disabled.
- [D008](../decisions/D008-validation-row-per-change.md): every change carries its validation row; the nested sandbox is the only shell start.
- [D009](../decisions/D009-one-manifest-judge-under-node.md): one manifest judge shared by shell and scripts.
- [D010](../decisions/D010-facade-scope-not-sandbox.md): a static check plus a scoped API object, not a process sandbox.
- [D011](../decisions/D011-native-manifest-no-cross-shell-compatibility.md): the manifest and the plugin API are v2's own; no other shell's plugins are supported.
- [D012](../decisions/D012-core-owns-lent-objects.md): the core owns every session-wide object and lends it per instance with disposers.

## Topics

- [plugins.md](plugins.md): read before writing a plugin, a host or the manager.
- [runtime.md](runtime.md): read before touching anything that starts, stops, measures or talks to the shell.
- [memory.md](memory.md): read before attributing memory growth or writing a memory budget.
