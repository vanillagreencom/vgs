# v2 architecture

A Quickshell shell for Hyprland. A small fixed core owns the process, the compositor connection, the theme tokens, the surface hosts, the plugin loader and the plugin manager. Everything a user sees or a service does is a plugin, and every plugin carries the validation row that proves it is built, shown and handed what it asked for. The smoke measures the shell's startup and reconcile latency and its resident size against budgets; no row measures one plugin alone.

## The one idea

Everything outside the core is a plugin, [D003](../decisions/D003-everything-is-a-plugin.md). The plugin is the unit of change and the core is the foundation it stands on. The core changes rarely, fits in one agent's context, and names no plugin. A plugin is one directory with one manifest, declares every surface it can fill and every core capability it uses, and is shown on each surface whose host exists. Plugins do not depend on one another. A change that needs a new core capability lands the capability first, with its own validation row, then the plugin that uses it. The plugin manager is part of the core, because it must exist before any plugin does and must keep working when a plugin breaks.

## Vocabulary

- Core: the runner, the instance lock, the Hyprland connection and its reply judge, the design system, the hosts, the plugin registry, the plugin manager and the IPC surface. `scripts/check-plugin-boundary.py` draws the line.
- Plugin: a directory with `manifest.json` at its root, in the schema [plugins.md](plugins.md) states, plus one QML entry point per kind.
- Kind: one of `bar-widget`, `bar`, `panel`, `overlay`, `menu`, `service`, `background`. A kind is a surface the core can host, and every kind has a host. The core owns the list; a new kind is a core change.
- Host: a core-owned Wayland surface a plugin draws inside. A plugin creates no surface of its own; a popup an overlay component opens is a child of the host surface and dies with the instance that declared it.
- Bar: the plugin of kind `bar` that is active. It declares three section containers the core mounts bar widgets into; it owns their geometry and its own built-in widgets.
- Built-in widget: a widget a plugin draws itself inside its own surface, such as the shipped bar's clock. It is part of that plugin, not a plugin and not a kind. The plugin registers it through its `builtins` capability, and the build records list it under the plugin's host key as `<plugin id>/<name>` with origin `plugin` and the registering instance's kind. [D013](../decisions/D013-built-in-widgets-are-the-bar-plugins.md) records the choice.
- Bar widget: a plugin of kind `bar-widget`. It draws one item in a bar section.
- Service: a plugin of kind `service`. No surface. It owns watchers, pollers and subprocesses.
- Capability: a core API a plugin names in its manifest and receives on its scoped `shell` object at load. Its provider is made for one instance, and everything the instance registers through it is released when the instance is destroyed.
- Status: runtime values a plugin declares in its manifest and publishes through capability `status`, held once per plugin for its instances and the Settings page.
- Plugin manager: the core component that discovers, validates, enables and disables plugins, and installs, updates and removes them. Its user interface is the Settings plugin, `vgs.settings`, through the `manager` capability; its mechanism is core.
- Requirement: an external command a plugin or the core runs, declared with its package per manager in a manifest's `requirements` or in `config/requirements.json`. It names a command, never a plugin; the scan probes it and the manager reports its state: [requirements.md](requirements.md).
- Token: one named value the shell draws with, typed and defaulted in `shell/Commons/Tokens.js`, read as `Theme.<group>.<token>`. A theme is a document that overrides tokens; the defaults are the `vgs` theme.
- Component: one type of `qs.Ui` that draws from tokens alone, listed in `shell/Ui/qmldir`. A plugin composes components; it draws a value of its own only through a token, or through its own judged table when it owns its look ([appearance.md](appearance.md)).
- Floating TUI: a core terminal window that runs one command as argv under the VGS presentation ([tui.md](tui.md)).
- Budget: a ceiling a validation row asserts in the nested sandbox.
- Validation row: an assertion under `scripts/smoke/rows/` that a plugin is built, shown and handed what it asked for, read back from the instance. A plugin without one does not merge.

## Boundaries

- Core: depends on Quickshell, Qt, the Hyprland socket and `config/shell.json`. Contains no plugin code and no plugin name. Enforced by `scripts/check-plugin-boundary.py`.
- Plugin: depends on the import set [plugins.md § Isolation](plugins.md#isolation) lists, the capabilities its manifest names, and its own directory. Enforced by the same check.
- Plugin manager: depends on the core and git. Runs no code from a plugin. Enforced by the install rows in `scripts/test-vgsh.sh`.
- Validation: depends on the nested compositor sandbox, built from the repository alone, with its runtime dir under the host's `XDG_RUNTIME_DIR`. Never touches the live session.
- Packages: `shell/Core/PackageManagers.js` is the one package-manager table. The shell never elevates for a package. Enforced for the table by `scripts/test-vgsh-pkg.js`.
- The plugin boundary is a static import check plus a scoped API object. It is not a process sandbox. Read [plugins.md § Isolation](plugins.md#isolation) before relying on it.

## Invariants

1. One shell process per session. The runner holds the lock, records its pid, and the shell draws and accepts state changes only when its process is the runner's; the CLI addresses that pid alone. Enforced by `scripts/test-vgsh.sh` (lock contention, argument refusal, pid selection) and `scripts/smoke/rows/instance-guard.sh`, which starts a bare `qs` beside the runner and asserts it neither draws, writes nor follows the applied theme package, with an ungated shell copy that follows as its control.
2. Every Wayland object the shell creates is dispatched or destroyed. No check enforces it. A long sampled session with `scripts/sample-shell-memory.sh` is the instrument.
3. A disabled plugin leaves the core's build records and the bar, and a disabled bar leaves no surface and reserves no space. Enforced by the disable rows in `scripts/smoke/rows/bar.sh`, which read the compositor's layer list and reserved geometry. That no object of it remains is not checked.
4. A plugin receives exactly the capabilities its own manifest names, a disabled plugin holds none of them, and a running plugin holds the settings the configuration currently gives it. Enforced by the fixture rows in `scripts/smoke/rows/plugins.sh` and `scripts/smoke/rows/capability-release.sh`, which read the fixture instances and the core's lending record back.
5. The plugin manager runs no plugin code and asks for no privilege. Enforced by the install rows in `scripts/test-vgsh.sh`, which run every git call with hooks off and install from local repositories.
6. Every decision about a manifest, the shape of `shell.json`, the merged configuration, enablement, the settings entry a kind reads and placement is made once in `shell/Core/PluginLogic.js`. Enforced by `scripts/test-plugin-logic.js` and by `bin/lib/check-manifests.js`, which loads the same file.
7. A figure in a document names the tool and the run that produced it. Enforced by review; `docs/architecture/memory.md` names its provenance in its first paragraph.

## Decisions

One line per decision record is in [decisions.md](decisions.md); the full log is [INDEX.md](../decisions/INDEX.md).

## Topics

- [plugins.md](plugins.md): read before writing a plugin or a host.
- [capabilities.md](capabilities.md): read before touching a capability's provider, its lending record or its release.
- [appearance.md](appearance.md): read before writing a plugin that owns its look, or touching `Theme.appearance` or its judge.
- [layers.md](layers.md): read before drawing a passive surface that takes no keyboard, or touching the `layers` capability or its host.
- [hyprland.md](hyprland.md): read before touching the Hyprland layer, a manifest's `hyprland` key, a `plugins[].keys` entry or `vgsh hypr`.
- [status.md](status.md): read before touching plugin status or the Settings page's Status rows.
- [manager.md](manager.md): read before touching enablement, install, update, remove or the Settings window.
- [configuration.md](configuration.md): read before touching the configuration files or their judge.
- [design-system.md](design-system.md): read before touching a token, the theme judge, `Theme`, or any value a surface draws with.
- [components.md](components.md): read before adding or changing a component of `qs.Ui`.
- [themes.md](themes.md): read before touching a theme package, package judge, or theme runner.
- [theme-apply.md](theme-apply.md): read before touching the apply, a reload hook or `vgsh theme reload`.
- [theme-follow.md](theme-follow.md): read before touching `applied.json`, `vgsh theme follow` or the `modified` flag.
- [theme-catalog.md](theme-catalog.md): read before touching `themes/catalog/`, its index or `vgsh-theme-judge catalog-check`.
- [theme-capability.md](theme-capability.md): read before touching `ThemeRunner` or the `theme` capability.
- [theme-targets.md](theme-targets.md): read before touching a theme target, a template or an encoder.
- [theme-wiring.md](theme-wiring.md): read before touching the wiring text, the profile wiring or the entry form's links.
- [theme-editors.md](theme-editors.md): read before touching an editor's target or its one-time step.
- [theme-toolkits.md](theme-toolkits.md): read before touching the GTK, Qt, KDE or icon theme target.
- [theme-tool-targets.md](theme-tool-targets.md): read before touching a Discord client's, btop's, fastfetch's, tmux's, Oh My Posh's or Obsidian's target.
- [theme-browsers.md](theme-browsers.md): read before touching the Zen or pywalfox target, or a target's `profiles` wiring.
- [theme-agents.md](theme-agents.md): read before touching an agent CLI's target or a target's `select` key.
- [packages.md](packages.md): read before touching the package-manager table or `vgsh pkg`.
- [requirements.md](requirements.md): read before touching a manifest's `requirements`, `config/requirements.json`, the scan's probe or the `missing` lines.
- [tui.md](tui.md): read before touching a floating TUI.
- [runtime.md](runtime.md): read before touching anything that starts, stops, measures or talks to the shell.
- [validation.md](validation.md): read before touching `scripts/validate`, the nested sandbox, its harness or a smoke row's verdict.
- [distribution.md](distribution.md): read before touching the licence, `VERSION`, `vgsh --version` or anything that packages or installs VGS.
- [memory.md](memory.md): read before attributing memory growth or writing a memory budget.
- [decisions.md](decisions.md): read for the one-line list of decisions, and add a line there with each new decision record.
