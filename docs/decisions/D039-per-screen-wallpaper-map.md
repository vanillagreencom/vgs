# D039: Wallpaper is per screen through an additive map that a theme apply clears

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Revisited

**Research**: VGS-544, [docs/plans/v2-platform-roadmap.md § vgs.themes](../plans/v2-platform-roadmap.md#vgsthemes-catalog-per-screen-wallpaper-browsers-issues-29-41)

**Context**: Every screen draws the one `current` image in `backgrounds.json`, and no command shows an image the user chose. Users with more than one monitor want a different image per monitor, and the wallpaper browser needs a command that sets one image, for every screen or for one. v1 did this with a per-monitor mode flag. Enabling the flag had to seed four maps from what each screen showed, so that turning the mode on changed nothing on screen. The first version seeded at one enable site and left three enable sites unseeded (v1 `origin/v1:docs/decisions/D010-single-screen-wallpaper-apply.md`, amendment).

**Decision**:

- `backgrounds.json` gains `screens: { "<output>": { "path", "stamp" } }`. An entry overrides `current` on that Hyprland output alone. An output with no entry shows `current`. There is no mode flag.
- `schemaVersion` stays 1. The writer includes `screens` only while it names an output. A file without the key is therefore a current file with no screen image, not an older format. The judge in `bin/lib/theme-backgrounds.js` accepts four keys, or five with a well-formed `screens`, and refuses anything else as `malformed`.
- `vgsh theme background set <path>` makes an image current and keeps `screens`. `set <path> --screen <output>` writes that output's entry alone. `set` takes exactly an image that `vgsh theme background list --all` names: a regular, non-symlinked file in an accepted package's `backgrounds/` or in the user folder `~/.config/vgs/backgrounds/`. The judge checks the output name's shape and never asks Hyprland, so an entry can wait for a monitor that is not connected.
- A theme apply clears `screens`. `next` and `previous` act on `current` and keep `screens`.
- `set` without `--screen` remembers the image in `themes` only when it belongs to the applied package, so a later step moves on from it and a later apply shows it again.

**Rationale**:

- An additive map needs no mode and no seeding. The absence of an entry is the "same as every screen" state. v1's seeding defect cannot exist here because there is no off-to-on edge to seed.
- A theme apply means "this theme everywhere". A screen that keeps an image from the previous theme contradicts that. Setting a screen again is one keystroke in the wallpaper browser.
- Omitting the empty map keeps every existing state file valid under the same version, with no reader for an older format. That reader is compatibility code the project does not write. A version 2 would need that reader, or it would refuse every state file already on disk, and every apply would then fail as `malformed`. `shell/plugins/vgs.themes/WallpaperState.qml` reads only `current` and `stamp`, so it needs no change.
- `set` accepts only what `list --all` names, so the browser can offer nothing that `set` refuses. The package trust rule ([D031](D031-installed-themes-render-code-targets.md): no symlink below a package directory) and the image-name rule each have one owner, and the user folder is read by the same rule. The real-path match above `backgrounds/` lets a path through a symlinked `~/.config` reach the same folder. The state still names the image by the folder's own path.
- Remembering only the applied package's image keeps `themes` a per-package list of images inside that package. An image from another package or from the user folder is not in the list that `next` cycles through.

## Omarchy comparison

At `basecamp/omarchy` `e332dc97`, Omarchy has one background for every monitor:

- `bin/omarchy-theme-bg-set` resolves any file with `realpath` and points one symlink, `~/.local/state/omarchy/current/background`, at it. It checks no folder, image type or symlink.
- `shell/plugins/background/Background.qml` builds one `PanelWindow` per screen through `Variants { model: Quickshell.screens }`. Each window draws that one link. `bin/omarchy-upgrade-to-quattro` removes `swaybg`, the retired default package, so no second wallpaper process remains.
- `bin/omarchy-theme-bg-next` cycles the theme's `backgrounds/` together with a per-theme user folder, `~/.config/omarchy/backgrounds/<theme>/`, and follows symlinks with `find -L`.
- `bin/omarchy-theme-set` (`remember_current_theme_background`) remembers whatever the link names when the user leaves a theme.

VGS takes Omarchy's single link for `current` and its per-theme memory. It differs in four places:

- VGS adds the per-output map, because Omarchy has no per-monitor wallpaper.
- `set` accepts only package and user-folder images, so the state never names an arbitrary file.
- The user folder is one flat folder outside the step cycle. A theme's `next` stays inside its own package.
- No symlink is followed below `backgrounds/`, which matches how VGS already reads packages.

## Alternatives Considered

- **v1's per-monitor mode flag with seeding.** Rejected. The flag adds a second state that every writer must keep in step with the maps, and seeding exists only to make that flag safe. v1 shipped a seeding defect at three of four enable sites.
- **`schemaVersion` 2 with a reader for version 1.** Rejected. It is compatibility code for the project's own format, and the additive key makes it unnecessary.
- **Keep `screens` across an apply.** Rejected. After an apply, a screen could keep an image from another theme, which breaks "apply a theme" as one action.
- **Query Hyprland for the output list in `set`.** Rejected. The theme judge never contacts the session. Its tests run without one, and a disconnected monitor keeps its entry.

**Revisit When**: A screen needs a setting beyond its image, such as a fill mode, or an apply must keep a screen's own image.

**Verification**: `scripts/test-vgsh-backgrounds.sh` covers `set` with and without `--screen`, each refusal, `list` and `list --all`, an apply that clears `screens`, steps that keep it, the writer that omits an empty map, and the refusal of a malformed map. Each rule has a must-fail control on a tree copy.

**References**: [D031](D031-installed-themes-render-code-targets.md), [theme-backgrounds.md](../architecture/theme-backgrounds.md), VGS-545 (drawing each screen's image), VGS-546 (the `theme` capability's `images` and `set`)

## Revisit Outcome (2026-09-29, VGS-550)

The decision holds. The wallpaper browser's All monitors choice must show one image on every screen, and `set` without `--screen` keeps each screen's own image, so the choice would not do what its label says. `vgsh theme background set <path> --every-screen` clears `screens`, then sets `current` as `set` without `--screen` does, under the same theme lock and judge; it excludes `--screen`, and its result names the screen `*`, which no output name can be ([theme-backgrounds.md § Commands](../architecture/theme-backgrounds.md#commands)). The theme capability's `set(path, "*", done)` runs it. The map stays additive with no mode flag: every screen showing `current` is still the absence of entries, and `--every-screen` returns to that state in one write. `scripts/test-vgsh-backgrounds.sh` covers it, with a judge copy that keeps `screens` as its control.
