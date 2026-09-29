# Topics

One line per architecture document: the change to read it before. [overview.md](overview.md) holds the idea, the vocabulary and the invariants.

- [plugins.md](plugins.md): read before writing a plugin or a host.
- [surfaces.md](surfaces.md): read before touching the summon host, an application window, a popup a summon builds, or a plugin's choice between a window and an overlay.
- [capabilities.md](capabilities.md): read before touching a capability's provider, its lending record or its release.
- [appearance.md](appearance.md): read before writing a plugin that owns its look, or touching `Theme.appearance` or its judge.
- [layers.md](layers.md): read before drawing a passive surface that takes no keyboard, or touching the `layers` capability or its host.
- [hyprland.md](hyprland.md): read before touching the Hyprland layer, a manifest's `hyprland` key, a `plugins[].keys` entry or `vgsh hypr`.
- [status.md](status.md): read before touching plugin status or the Settings page's Status rows.
- [notification-senders.md](notification-senders.md): read before touching a notification rule's senders, a browser's site address, the copies of one message, or the Slack photo cache and its tokens.
- [manager.md](manager.md): read before touching enablement, install, update, remove or the Settings window.
- [configuration.md](configuration.md): read before touching the configuration files or their judge.
- [design-system.md](design-system.md): read before touching a token, the theme judge, `Theme`, or any value a surface draws with.
- [components.md](components.md): read before adding or changing a component of `qs.Ui`.
- [themes.md](themes.md): read before touching a theme package, package judge, or theme runner.
- [theme-apply.md](theme-apply.md) and [theme-reload.md](theme-reload.md): read before touching the apply, a reload hook or `vgsh theme reload`.
- [theme-follow.md](theme-follow.md): read before touching `applied.json`, `vgsh theme follow` or the `modified` flag.
- [theme-catalog.md](theme-catalog.md): read before touching `themes/catalog/`, its index, `vgsh-theme-judge catalog-check` or a catalog install.
- [theme-conversion.md](theme-conversion.md): read before touching the v1 theme converter or the catalog readability check.
- [theme-wallpapers.md](theme-wallpapers.md): read before touching `vgsh theme wallpapers`, the theme-asset cache or `bin/lib/theme-download.js`.
- [theme-install.md](theme-install.md): read before touching `vgsh theme add`, `update`, `remove` or `outdated`.
- [theme-capability.md](theme-capability.md): read before touching `ThemeRunner` or the `theme` capability.
- [theme-targets.md](theme-targets.md): read before touching a theme target, a template or an encoder.
- [theme-wiring.md](theme-wiring.md): read before touching the wiring text, the profile wiring or the entry form's links.
- [theme-editors.md](theme-editors.md): read before touching an editor's target or its one-time step.
- [theme-toolkits.md](theme-toolkits.md): read before touching the GTK, Qt, KDE or icon theme target.
- [theme-tool-targets.md](theme-tool-targets.md): read before touching a Discord client's, btop's, fastfetch's, tmux's, Oh My Posh's, Obsidian's or gum's target.
- [theme-browsers.md](theme-browsers.md): read before touching the Zen or pywalfox target, or a target's `profiles` wiring.
- [theme-agents.md](theme-agents.md): read before touching an agent CLI's target or a target's `select` key.
- [packages.md](packages.md): read before touching the package-manager table or `vgsh pkg`.
- [requirements.md](requirements.md) and [requirement-notice.md](requirement-notice.md): read before touching a manifest's `requirements`, `config/requirements.json`, the scan's probe, the `missing` lines or the notice.
- [tui.md](tui.md), [tui-capability.md](tui-capability.md), [tui-records.md](tui-records.md) and [tui-sudo.md](tui-sudo.md): read before touching a floating TUI, the `tui` capability, its exit records or `vgsh sudo`.
- [runtime.md](runtime.md): read before touching anything that starts, stops, measures or talks to the shell.
- [validation.md](validation.md) and [validation-smoke.md](validation-smoke.md): read before touching `scripts/validate`, the nested sandbox, its harness or a smoke row's verdict.
- [validation-latency.md](validation-latency.md): read before touching a latency the smoke reads or its budget.
- [distribution.md](distribution.md): read before touching the licence, `VERSION`, `vgsh --version` or anything that packages or installs VGS; it links each channel's file.
- [memory.md](memory.md): read before attributing memory growth or writing a memory budget.
- [decisions.md](decisions.md): read for the one-line list of decisions, and add a line there with each new decision record.
