# Background

The applied theme's background image on every screen, under every window.

## Features

- `bin/vgsh theme apply <name>` shows the package's remembered image, else the first of its `backgrounds/` directory in name order. A package without images shows the theme's background colour.
- `bin/vgsh theme background next` shows the applied package's next image and remembers it for that package, so applying the package again shows it.
- The image is cropped to fill each screen.
- `~/.local/state/vgs/background` links to the same image, for a lock screen or any other application that draws it.
- `bin/vgsh plugin disable vgs.background` removes the surface, so a wallpaper another program draws shows again.

## Settings

None.
