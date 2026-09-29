# Themes

A bar button that opens a panel listing every theme package, a full-screen theme browser and wallpaper browser, and the applied theme's wallpaper on every screen, under every window. A click on a package applies it to the shell and to every application the theme targets.

## Features

- A Themes button for the bar. The shipped bar does not show it: `bin/vgsh plugin enable vgs.themes` adds it to the right section.
- One row per package, shipped and installed, with its colours, the package the shell displays, and a package that is refused or hidden by an installed one of the same name.
- A Catalog section with every catalog theme, its colours, mode and the same wallpaper archive size text as the browser. Install adds the theme definition. Download wallpapers fetches the archive for an installed catalog theme that has no wallpapers.
- A catalog row shows Installing while an install runs. It shows the browser's progress text while a wallpaper download runs. A click on an installed catalog row applies it.
- Add from URL opens the floating TUI for `bin/vgsh theme add`, asks for a git URL, then offers to apply the new theme.
- A click on a row applies that package, as `bin/vgsh theme apply <name>` does.
- A full-screen theme browser opens on `SUPER+T`. It lists shipped, installed and catalog themes as angled cards. Type to filter. Select All or Installed. Press Enter, or click the selected card, to install a catalog theme when needed and apply it.
- After a catalog theme applies without its wallpapers, the browser asks whether to download them. Download shows progress, unpacks the wallpapers and applies the theme again so its first wallpaper shows. Not now leaves the theme applied without its wallpapers.
- The last apply's problems on its package's row, until the next apply: each application target that failed, with its reason, and each file of an installed package the apply dropped because its target runs code, as `bin/vgsh theme apply` reports it with `dropped=`.
- A Modified badge when `~/.config/vgs/theme.json` no longer matches the package it names. Apply the package again to revert the edit.
- Closing the panel does not stop an apply. The panel shows the result when it opens again.
- The applied package's wallpaper: `bin/vgsh theme apply <name>` shows the package's remembered image, else the first of its `backgrounds/` directory in name order. With a package without images nothing is drawn, so a wallpaper another program draws shows.
- The image is cropped to fill each screen.
- A full-screen wallpaper browser opens on `SUPER+W`. Theme lists the applied theme's wallpapers. All lists every theme's wallpapers and the user folder's, `~/.config/vgs/backgrounds/`, each badged with where it comes from. The browser starts on the image shown now. Press Enter, or click the selected card, to set the image.
- With two or more monitors, the wallpaper browser shows All monitors and This monitor. Each open starts on All monitors, which sets the image on every monitor and clears each monitor's own image. This monitor sets it on the monitor the browser shows on alone.
- When the applied catalog theme's wallpapers are missing, or the catalog has newer ones, Theme ends with a Download or Update card. Enter on it downloads them with progress, applies the theme again so its wallpaper shows, and keeps the browser open.
- A monitor shows its own image once `bin/vgsh theme background set <path> --screen <output>` names it, and every other monitor keeps the current image. `--every-screen` in place of `--screen` shows the image on every monitor and clears each monitor's own image. A monitor whose own image was deleted shows the current image. The next apply of a package clears every monitor's own image.
- A Wallpaper section in the panel names the current image, and its Previous and Next buttons show the package's previous or next image and remember it for the package, as `bin/vgsh theme background previous` and `next` do. Applying the package again shows the remembered image.
- `~/.local/state/vgs/background` links to the same image, for a lock screen or any other application that draws it.
- `bin/vgsh plugin disable vgs.themes` turns off the button, the panel and the wallpaper.

## Keys

- `SUPER+T`: open or close the full-screen theme browser. In the wallpaper browser, open the theme browser.
- `SUPER+W`: open or close the full-screen wallpaper browser. In the theme browser, open the wallpaper browser.

In the theme browser:

- `Left`, `Right`, `Tab`, `Shift+Tab`, `Home`, `End` and the wheel: move through cards.
- `Up` and `Down`: move through cards.
- `Enter`: install when needed, then apply.
- `Esc`: clear the filter. Press it again to close.
- Typing: filter by package name or label.
- Click on a side card: select it. Click on the selected card: apply it. Click the scrim: close.

In the wallpaper browser:

- `Left`, `Up`, `A`, `Right`, `Down`, `D`, `Home`, `End` and the wheel: move through cards.
- `S`: switch between Theme and All.
- `W`, `Tab` and `Shift+Tab`: switch between All monitors and This monitor. With one monitor, `Tab` and `Shift+Tab` move through cards.
- `Enter`: set the image, or run the Download or Update card.
- `Esc`: close.
- Click on a side card: select it. Click on the selected card: set it. Click the scrim: close.

The plugin declares both shortcuts in its manifest. Remove the owner's old `SUPER+T` v1 theme-picker line and `SUPER+W` v1 wallpaper-picker line from `~/.config/hypr/config/keybinds.lua` before using these keys, because Hyprland fires every matching bind.

## Capabilities

- `theme`: list packages, read the catalog, install a catalog package, apply a package, list and set images, and download or update wallpapers.
- `surfaces`: open the panel and the full-screen browser, and close them from their own controls.
- `shortcut`: register `vgs.themes:themes` and `vgs.themes:wallpapers`, which the manifest binds to `SUPER+T` and `SUPER+W`.
- `screens`: count the monitors for the wallpaper browser's monitor choice, and name the monitor it shows on.

## Settings

On the plugin's row in `plugins` in `~/.config/vgs/shell.json`, for example `{ "id": "vgs.themes", "placement": "top-right" }`:

- `placement`: where the panel opens when it is summoned without the button, for example from `bin/vgsh ipc call shell summon panel vgs.themes '{}'`, one of `top-left`, `top`, `top-right`, `left`, `center`, `right`, `bottom-left`, `bottom` and `bottom-right`. The plugin's Settings page offers the same list. Default: `top-right`.
