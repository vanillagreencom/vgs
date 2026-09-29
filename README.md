# VGS v2

A desktop shell for Hyprland on Quickshell. Everything is a plugin: the bar, the widgets you add to it, every panel, every background service. A small fixed core starts the shell, hosts the surfaces and loads plugins, and each plugin ships with the check that proves it is built and handed what it asked for.

## Install

There is no install command. From a checkout, `bin/vgsh run` starts the shell. `bin/vgsh --version` prints the version.

## Features

- Everything is a plugin. A plugin is one directory with a manifest; the shell shows it on every surface it declares.
- One manifest format, judged once, with every field in [docs/architecture/plugins.md](docs/architecture/plugins.md).
- A Settings window, `SUPER+M` or the gear in the bar: every plugin with a page of its details, its settings and its keys, and a switch to turn it on or off.
- A plugin manager on the command line: `bin/vgsh plugin list`, `enable`, `disable`, `validate`, and `add <git url>`, `update` and `remove`. Install runs no code from the plugin and leaves it disabled until you enable it.
- Plugins never depend on each other. When the surface a plugin draws on is absent, that part is hidden and the rest keeps working.
- A validation sandbox that runs the whole shell inside a nested compositor and never touches your session.
- Hyprland keys and blur from plugins, and window borders in the theme's colours. Hyprland is configured in Lua only: the shell writes one Lua file, and one line in your `hyprland.lua` loads it. A classic `hyprland.conf` is not supported.

## Shipped plugins

| Plugin | What it does |
|---|---|
| [Bar](shell/plugins/vgs.bar/README.md) | The bar across the top of every screen, with its built-in workspaces and clock, and three sections for plugin widgets. |
| [Settings](shell/plugins/vgs.settings/README.md) | A window that lists every plugin and opens a page for each, with its details, settings and keys. `SUPER+M` or the gear in the bar opens it. |
| [Themes](shell/plugins/vgs.themes/README.md) | A bar button and a panel that list every theme package and apply one with a click, and the applied theme's wallpaper on every screen, with Previous and Next in the panel. `bin/vgsh plugin enable vgs.themes` adds the button to the bar. |

## How it works

- `bin/vgsh run` takes the instance lock and starts one shell for the session.
- `bin/vgsh restart` refuses while locked, then stops the recorded pid and relaunches through Hyprland. It returns after the new shell answers as the guarded instance.
- The shell reads `config/shell.json`, then your `~/.config/vgs/shell.json`, and enables the plugins those name.
- Each plugin is shown on the surfaces it declares. A widget appears in the bar, a service runs with no surface.
- `bin/vgsh plugin disable <id>` writes your file; the shell watches it and updates the screen. Disable keeps the plugin's placement and settings, so enable restores it as it was.
- The shell writes `~/.local/state/vgs/hypr/vgs.lua` with the theme's border colours and each enabled plugin's keys and blur rules, and reloads Hyprland when it changes. On its first run it adds `pcall(dofile, "…/vgs.lua")` as the first line of `~/.config/hypr/hyprland.lua` if that file exists; `bin/vgsh hypr wire` and `unwire` add and remove the line. Settings after that line win. See [docs/architecture/hyprland.md](docs/architecture/hyprland.md).

## Settings

- `~/.config/vgs/shell.json`: which bar is active, which widgets sit in which section, which plugins are on.
- `~/.config/vgs/theme.json`: the theme, a document that overrides any design token every plugin reads: colours, fonts, spacing, radius and motion.
- A widget's settings sit inline on its layout entry, for example `{ "id": "acme.weather", "units": "metric" }`; every other plugin's sit on its row in `plugins`, for example `{ "id": "vgs.bar", "clockFormat": "HH:mm" }`. A change reaches the running plugin without a restart.
- A plugin's Hyprland keys sit in `keys` on its row in `plugins`, for example `{ "id": "vgs.launcher", "keys": { "toggle": "SUPER+ALT+SPACE" } }`; `null` unbinds a key. The Settings window writes both.

## Writing a plugin

Read [docs/architecture/plugins.md](docs/architecture/plugins.md). An agent loads the `vgs-plugin` skill, which scaffolds a plugin from templates and checks it.

## Licence

VGS is under the MIT licence: [LICENSE](LICENSE). The bundled fonts, JetBrains Mono and Inter, are under the SIL Open Font License 1.1 (`shell/assets/fonts/*-OFL.txt`), and the Lucide icons under ISC ([shell/Ui/icons/LICENSE](shell/Ui/icons/LICENSE)). The package licence is `MIT AND OFL-1.1 AND ISC`.
