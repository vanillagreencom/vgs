# D020: A theme with no shipped screenshot paints a drawn palette card; no install captures one

[← Decision Index](INDEX.md)

**Date**: 2026-09-15 **Status**: Active **Research**: —

**Context**: The settings Current Theme card, the Dash Themes tab and the theme switcher each started `theme preview --all` on open. The helper reported no `preview` for a theme the user had restyled or overlaid, even when its package shipped `preview.jpg`, so an edited built-in theme sent every open into a capture: a nested Hyprland session on a hidden headless output, with ghostty, nvim, a file manager and a Quickshell flyout, captured by grim. Across the install channels, only grim is a declared dependency everywhere. Hyprland is absent under Niri, ghostty is an Arch optional dependency only, no recipe declares nvim, and `config/vshell/dependencies.json` already calls `dbus-run-session` repository tooling. The capture also depends on runtime window rules on the user's compositor.

**Decision**: `theme_preview` in `bin/vshell_helper.py` owns the one answer every surface paints. The package's `preview.jpg` wins whether or not the user edited the theme. A theme with no shipped screenshot gets a palette card, its background with a foreground bar, an accent bar and its 16 colours, encoded as PNG with `zlib` alone and cached under a key over those colours. The shell starts no preview command, and the `theme preview` subcommand is gone. The capture code stays in the helper for `scripts/capture-theme-previews.py` alone, which a maintainer runs from a Hyprland session to produce the shipped screenshots.

**Rationale**:

- A dependency that most channels do not ship, and a compositor Niri users do not run, cannot back a feature every install shows.
- A shipped screenshot of the base theme identifies the theme a restyle started from; a spinner or "Rendering…" identifies nothing.
- The card needs no tool, draws in one list call, and changes only when the colours it paints change, so no surface waits on it.

**Alternatives considered**:

- Keep the capture and fall back to the card when a dependency is missing: two preview paths, and the capture still runs on the owner's machine at every open after an edit.
- Draw the card in QML: the switcher's carousel paints image files, so the three surfaces would need two renderers to show the same picture.
- Composite the palette over the wallpaper: decoding a wallpaper needs Pillow or an external tool, which not every channel ships.

**Revisit When**: every install channel ships the capture's tools and it can run under Niri, or users ask for an edited theme's preview to show its edits.

**Verification**: `test_theme_list_reports_the_preview_and_the_thumbnail_apart` in `scripts/check-vshell-helper.py` lists themes with no tool on `PATH` and Pillow blocked; `scripts/test-switcher-selection.js` checks that the settings card and the Dash row paint the listed `preview` and that no surface starts a preview command.

**References**: [D015](D015-theme-imagery-release-assets.md) (shipped previews), [theme.md](../architecture/theme.md).
