# Bar

The bar across the top of every screen. It holds bar widgets in a left, a center and a right section.

## Features

- One bar per screen, above windows, with space reserved so windows never sit under it.
- Three sections. Widgets are placed by editing `bar.layout` in `~/.config/vgs/shell.json` or with `bin/vgsh plugin enable <id>`.
- Colours and font follow `~/.config/vgs/theme.json`.

## Limits

- Only one bar is active at a time. Disabling it hides every bar widget until a bar is enabled again.
