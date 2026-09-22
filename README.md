# VGS v2

A desktop shell for Hyprland on Quickshell. Everything is a plugin: the bar, every widget in it, every panel, every background service. A small fixed core starts the shell, hosts the surfaces and loads plugins, and each plugin ships with the check that keeps it fast and stable.

## Install

Not yet. The first release comes with its install command. From a checkout, `bin/vgsh run` starts the shell.

## Features

- Everything is a plugin. A plugin is one directory with a manifest; the shell shows it on every surface it declares.
- One manifest format, judged once, with every field in [docs/architecture/plugins.md](docs/architecture/plugins.md).
- A plugin manager: `bin/vgsh plugin list`, `enable`, `disable`, `validate`.
- Plugins never depend on each other. When the surface a plugin draws on is absent, that part is hidden and the rest keeps working.
- A validation sandbox that runs the whole shell inside a nested compositor and never touches your session.

## Shipped plugins

| Plugin | What it does |
|---|---|
| [Bar](shell/plugins/vgs.bar/README.md) | The bar. Three sections of widgets across the top of every screen. |
| [Clock](shell/plugins/vgs.clock/README.md) | Date and time in the bar. |
| [Workspaces](shell/plugins/vgs.workspaces/README.md) | Workspace numbers in the bar. Click one to focus it. |

## How it works

- `bin/vgsh run` takes the instance lock and starts one shell for the session.
- The shell reads `config/shell.json`, then your `~/.config/vgs/shell.json`, and enables the plugins those name.
- Each plugin is shown on the surfaces it declares. A widget appears in the bar, a service runs with no surface.
- `bin/vgsh plugin disable <id>` writes your file; the shell watches it and updates the screen. Disable keeps the plugin's placement and settings, so enable restores it as it was.

## Settings

- `~/.config/vgs/shell.json`: which bar is active, which widgets sit in which section, which plugins are on.
- `~/.config/vgs/theme.json`: the five palette colours every plugin reads.
- A widget's settings sit inline on its layout entry, for example `{ "id": "vgs.clock", "format": "HH:mm" }`; every other plugin's sit on its row in `plugins`. A change reaches the running plugin without a restart.

## Writing a plugin

Read [docs/architecture/plugins.md](docs/architecture/plugins.md). An agent loads the `vgs-plugin` skill, which scaffolds a plugin from templates and checks it.
