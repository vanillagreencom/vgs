# Bar

The bar across the top of every screen. It draws its own workspaces and clock, and holds plugin widgets in a left, a center and a right section.

## Features

- One bar per screen, above windows, with space reserved so windows never sit under it.
- Built-in workspaces: one number per existing workspace, lowest first, the focused one highlighted. Click a number to focus that workspace.
- Built-in clock: the date and time in the format you choose. It ticks once a minute, or once a second when the format shows seconds.
- Three sections for plugin widgets, after the built-ins in each section. Place a widget by editing `bar.layout` in `~/.config/vgs/shell.json` or with `bin/vgsh plugin enable <id>`.
- Colours and font follow `~/.config/vgs/theme.json`.

## Settings

On the bar's row in `plugins` in `~/.config/vgs/shell.json`, for example `{ "id": "vgs.bar", "clockFormat": "HH:mm" }`:

- `left`, `center`, `right`: the built-in widgets each section shows, in order, from `workspaces` and `clock`. Default: `["workspaces"]`, `["clock"]`, `[]`. An empty list hides them.
- `clockFormat`: the clock's format in Qt date format. Default: `ddd d MMM  HH:mm`.

## Limits

- Only one bar is active at a time. Disabling it hides every plugin widget until a bar is enabled again.
