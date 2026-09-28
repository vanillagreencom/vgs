# Background

The applied theme's background image on every screen, under every window.

## Features

- `bin/vgsh theme apply <name>` shows the package's remembered image, else the first of its `backgrounds/` directory in name order. With a package without images the plugin draws nothing, so a wallpaper another program draws shows.
- `bin/vgsh theme background next` shows the applied package's next image and remembers it for that package, so applying the package again shows it.
- The image is cropped to fill each screen.
- `~/.local/state/vgs/background` links to the same image, for a lock screen or any other application that draws it.
- `bin/vgsh plugin disable vgs.background` turns it off for every package.

## Settings

None.
