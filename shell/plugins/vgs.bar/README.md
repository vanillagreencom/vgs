# Bar

The bar across the top of every screen. It draws its own workspaces and clock, and holds plugin widgets in a left, a center and a right section.

![The bar with its workspaces, its clock and plugin widgets](../../../docs/images/plugins/vgs.bar-bar.webp)

Screenshot made with `scripts/readme-shots.sh` in the nested sandbox, with the default theme at scale 2.

## Features

- One bar per screen, above windows, with space reserved so windows never sit under it.
- Built-in workspaces: one number per existing workspace, lowest first, the focused one highlighted. Click a number to focus that workspace.
- Built-in clock: the date and time in the preset or custom format you choose. It ticks once a minute, or once a second when the format shows seconds.
- Three sections for plugin widgets, after the built-ins in each section. Enabling a plugin on its Settings page places its widget in the section its manifest names; `bar.layout` in `~/.config/vgs/shell.json` places it anywhere. The shipped layout puts the Settings gear, `vgs.settings`, in the right section.
- Colours, the font and every size follow the design tokens, so `~/.config/vgs/theme.json` restyles the bar.

## Settings

On the bar's row in `plugins` in `~/.config/vgs/shell.json`, for example `{ "id": "vgs.bar", "clockFormat": "HH:mm" }`:

- `left`, `center`, `right`: the built-in widgets each section shows, in order, from `workspaces` and `clock`. A name listed twice in one section is drawn once and the repeat is logged. `manager` draws nothing and logs `vgsh plugin enable vgs.settings`, which places the Settings gear instead. Default: `["workspaces"]`, `["clock"]`, `[]`. An empty list hides them. These lists are not on the Settings page, since the page draws no list.
- `clockFormat`: the clock's preset or custom date and time format. Default: `ddd d MMM  HH:mm`.

## Limits

- Only one bar is active at a time. Disabling it hides every plugin widget until a bar is enabled again.
