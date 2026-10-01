# Themes

A bar button that opens a panel listing every theme package, a full-screen theme browser and wallpaper browser, and the applied theme's wallpaper on every screen, under every window. A click on a package applies it to the shell and to every application the theme targets.

![The theme browser showing an installed theme](../../../docs/images/plugins/vgs.themes-browser.webp)

Screenshot made with `scripts/readme-shots.sh` in the nested sandbox, with the default theme at scale 2.

## Features

- A Themes button for the bar. The shipped bar does not show it: enabling the plugin on its Settings page adds it to the right section.
- One row per package, shipped and installed, with its colours, the package the shell displays, and a package that is refused or hidden by an installed one of the same name.
- A Catalog section with every catalog theme, its colours, mode and the same wallpaper archive size text as the browser. Install adds the theme definition. Download wallpapers fetches the archive for an installed catalog theme that has no wallpapers.
- A catalog row shows Installing while an install runs. It shows the browser's progress text while a wallpaper download runs. A click on an installed catalog row applies it.
- Add from URL, at the foot of the panel, opens the floating TUI for `bin/vgsh theme add`, asks for a git URL, then offers to apply the new theme.
- A click on a row applies that package, as `bin/vgsh theme apply <name>` does.
- A full-screen theme browser opens on `SUPER+T`. It lists shipped, installed and catalog themes as angled cards. A package `preview.png` draws first. Without it, the selected card draws a live desktop preview from the package's tokens and terminal colours. Side cards draw the package preview, wallpaper or palette. Type to filter; when no theme matches, Clear filter clears it, as `Esc` does. Select All or Installed. Press Enter, or click the selected card, to install a catalog theme when needed and apply it.
- After a catalog theme applies without its wallpapers, the browser asks whether to download them. Download shows progress, unpacks the wallpapers and applies the theme again so its first wallpaper shows. Not now leaves the theme applied without its wallpapers.
- The last apply's problems on its package's row, until the next apply: each application target that failed, with its reason, and each file of an installed package the apply dropped because its target runs code, as `bin/vgsh theme apply` reports it with `dropped=`.
- A Modified badge when `~/.config/vgs/theme.json` no longer matches the package it names. Apply the package again to revert the edit.
- Closing the panel does not stop an apply. The panel shows the result when it opens again.
- The applied package's wallpaper: `bin/vgsh theme apply <name>` shows the package's remembered image, else the first of its `backgrounds/` directory in name order. With a package without images nothing is drawn, so a wallpaper another program draws shows.
- The image is cropped to fill each screen.
- A full-screen wallpaper browser opens on `SUPER+W`. Theme lists the applied theme's wallpapers. All lists every theme's wallpapers and the user folder's, `~/.config/vgs/backgrounds/`, each badged with where it comes from. The browser starts on the image shown now. When the applied theme has no wallpapers, Show every source switches to All. Press Enter, or click the selected card, to set the image.
- With two or more monitors, the wallpaper browser shows All monitors and This monitor. Each open starts on All monitors, which sets the image on every monitor and clears each monitor's own image. This monitor sets it on the monitor the browser shows on alone.
- When the applied catalog theme's wallpapers are missing, or the catalog has newer ones, Theme ends with a Download or Update card. Enter on it downloads them with progress, applies the theme again so its wallpaper shows, and keeps the browser open.
- A monitor shows its own image once `bin/vgsh theme background set <path> --screen <output>` names it, and every other monitor keeps the current image. `--every-screen` in place of `--screen` shows the image on every monitor and clears each monitor's own image. A monitor whose own image was deleted shows the current image. The next apply of a package clears every monitor's own image.
- A Wallpaper section in the panel names the current image, and its Previous and Next buttons show the package's previous or next image and remember it for the package, as `bin/vgsh theme background previous` and `next` do. Applying the package again shows the remembered image.
- `~/.local/state/vgs/background` links to the same image, for a lock screen or any other application that draws it.
- Disabling the plugin on its Settings page turns off the button, the panel and the wallpaper.
- Browser theming: Chromium, Google Chrome, Microsoft Edge and Brave take the theme's background colour through a managed policy, whose writer is installed once. The plugin's Settings page shows whether it is, and while a Chromium-family browser is found without it, **Install browser theming** opens a floating terminal where sudo asks for your password ([theme-browsers.md § Chromium](../../../docs/architecture/theme-browsers.md#chromium)).

## Keys

- `SUPER+T`: open or close the full-screen theme browser. In the wallpaper browser, open the theme browser.
- `SUPER+W`: open or close the full-screen wallpaper browser. In the theme browser, open the wallpaper browser.
- `SUPER+CTRL+J`: open or close the Themes panel. VGS does not use `SUPER+CTRL+T` because Omarchy binds it to Activity.

In the Themes panel:

- `Up`, `Down`, `Home`, `End`, `PageUp` and `PageDown`: move the theme selection.
- Typing: jump to a theme by name.
- `Enter` or Space: apply an installed row, or install a catalog row.
- `Alt+D`: run the selected installed catalog row's Download wallpapers action when it is shown.
- `Esc`: close the panel.

In both full-screen browsers:

- `Tab`, `Shift+Tab`, `Ctrl+Tab`, `Ctrl+Shift+Tab`, `Ctrl+PageDown` and `Ctrl+PageUp`: switch between Themes and Wallpapers.
- `Left`, `Right`, `Up`, `Down`, `Home`, `End` and the wheel: move through cards.
- The user's Hyprland directional focus keys also move through cards while the browser is open.
- `Enter`: apply the selected theme, set the selected wallpaper, or run the Download or Update card.
- `Esc`: close. In the theme browser, it clears the filter first.
- Click on a side card: select it. Click on the selected card: apply it or set it. Click the scrim: close.

In the theme browser:

- `Alt+I`: switch between All and Installed.
- Typing: filter by package name or label.

In the wallpaper browser:

- `Alt+S`: switch between Theme and All.
- `Alt+M`: switch between All monitors and This monitor when that control is shown.
- Space: set the selected wallpaper or run the Download or Update card.

The plugin declares the browser and panel shortcuts in its manifest. The generated Hyprland layer captures the keyboard while the browser is open, so matching user window binds do not reach windows behind it.

## Capabilities

- `theme`: list packages, read the catalog, install a catalog package, apply a package, list and set images, download or update wallpapers, and fetch a selected catalog preview.
- `surfaces`: open the panel and the full-screen browser, and close them from their own controls.
- `shortcut`: register `vgs.themes:themes`, `vgs.themes:wallpapers` and `vgs.themes:panel`, which the manifest binds to `SUPER+T`, `SUPER+W` and `SUPER+CTRL+J`.
- `screens`: count the monitors for the wallpaper browser's monitor choice, and name the monitor it shows on.

## Settings

On the plugin's row in `plugins` in `~/.config/vgs/shell.json`, for example `{ "id": "vgs.themes", "placement": "top-right" }`:

- `placement`: where the panel opens when it is summoned without the button, for example from `bin/vgsh ipc call shell summon panel vgs.themes '{}'`, one of `top-left`, `top`, `top-right`, `left`, `center`, `right`, `bottom-left`, `bottom` and `bottom-right`. The plugin's Settings page offers the same list. Default: `top-right`.
- `setWindowBorders`: whether themes set Hyprland border colours, border thickness and shadow colour. A user's own Hyprland setting after the VGS include line still wins. Default: `true`.
- `setCornerRadius`: whether themes set Hyprland window radius, rounding power and grouped-window tab radius. A user's own Hyprland setting after the VGS include line still wins. Default: `true`.
- `setWindowAnimations`: whether themes set Hyprland window, layer, workspace and fade animation presets. A user's own Hyprland setting after the VGS include line still wins. Default: `false`.
