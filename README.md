# v2

A desktop shell for Hyprland on Quickshell. The core is small and fixed. Everything a user sees or a service does is a plugin, and every plugin carries the check that keeps it fast and stable.

## Install

Not yet. The first release comes with its install command. From a checkout, `bin/vgsh run` starts the shell.

## Features

- A bar with a clock and workspace numbers, each a plugin.
- A plugin manager: `bin/vgsh plugin list`, `enable`, `disable`, `validate`.
- One manifest format shared with Omarchy Quattro plugins.
- A nested validation sandbox that never touches the live session.

## How it works

- `bin/vgsh run` takes the instance lock and starts one shell for the session.
- The shell reads `config/shell.json`, then your `~/.config/vgs/shell.json`, and enables the plugins those name.
- The shell reads every plugin manifest under `shell/plugins/` and `~/.config/vgs/plugins/`.
- A plugin declares the surfaces it can fill. The shell shows each one whose host is active and skips the rest.
- `bin/vgsh plugin disable <id>` writes your file; the shell watches it and updates the screen.

## Settings

- `~/.config/vgs/shell.json`: which bar is active, which widgets sit in which section, which plugins are on.
- `~/.config/vgs/theme.json`: the five palette colours every plugin reads.
- A widget's settings sit inline on its layout entry, for example `{ "id": "vgs.clock", "format": "HH:mm" }`.
