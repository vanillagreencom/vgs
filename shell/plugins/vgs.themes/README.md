# Themes

A bar button that opens a panel listing every theme package. A click on a package applies it to the shell and to every application the theme targets.

## Features

- A Themes button for the bar. The shipped bar does not show it: `bin/vgsh plugin enable vgs.themes` adds it to the right section.
- One row per package, shipped and installed, with its colours, the package the shell displays, and a package that is refused or hidden by an installed one of the same name.
- A click on a row applies that package, as `bin/vgsh theme apply <name>` does.
- The last apply's problems on its package's row: each application target that failed, with its reason, until the next apply.
- A Modified badge when `~/.config/vgs/theme.json` no longer matches the package it names. Apply the package again to revert the edit.
- Closing the panel does not stop an apply. The panel shows the result when it opens again.

## Settings

On the plugin's row in `plugins` in `~/.config/vgs/shell.json`, for example `{ "id": "vgs.themes", "placement": "top-right" }`:

- `placement`: where the panel opens when it is summoned without the button, for example from `bin/vgsh ipc call shell summon panel vgs.themes '{}'`. Default: `top-right`.
