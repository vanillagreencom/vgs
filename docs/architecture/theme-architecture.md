# Theme architecture

## Purpose
VGS owns theme state and generated app themes.
No external theme-engine runtime dependency.
No legacy upstream shell runtime dependency.

Built-in curated theme packages (palettes, curated app files, wallpapers) come
from a few provenances, all with per-file author credits (e.g. btop.theme "By:"
lines) preserved verbatim:
- Packages imported from [Omarchy](https://github.com/basecamp/omarchy) (MIT,
  © David Heinemeier Hansson), plus community Omarchy theme packages published as
  standalone repos. Each ships an omarchy-format `colors.toml` (older packages
  ship an `alacritty.toml` converted to the 22-key set, with the accent taken
  from the package's Hyprland `col.active_border`). Editor themes are vendored
  into the repo: the curated `neovim.lua` colorscheme plugin lives under
  `config/vshell/nvim/colorschemes/`, and every package ships a bundled
  `apps/vscode-theme.json` (`curatedThemeFile`) — the official VS Code theme where
  one exists, else one derived from the nvim highlight colors. No marketplace
  extension or `vscode.json` pointer is used. Icon-theme pointers are normalized
  to the vendored Yaru variant set.
- Packages whose palettes are sourced from their upstream theme projects
  (e.g. Rosé Pine, Catppuccin, Tokyo Night, Kanagawa, Ayu, Dracula, Eldritch)
  and the [Noctalia](https://github.com/noctalia-dev/noctalia) shell's built-in
  palettes. Their curated editor themes are the upstream projects' own, vendored
  (nvim colorscheme under `config/vshell/nvim/colorschemes/`, VS Code theme
  bundled as `apps/vscode-theme.json`, upstream `btop` theme verbatim); terminal
  targets render from the accurate `colors.toml`.
- VGS-original packages (e.g. the `noctalia` signature package: hand-authored
  wallpaper and `btop.theme`, palette-derived editors).

## Sources
| Source | Path |
|--------|------|
| Built-in theme packages | `themes/<name>/` (dir with `theme.json`) |
| User theme packages | `~/.config/vshell/themes/<name>/` |
| Legacy v1 user blueprints | `~/.config/vshell/blueprints/*.json` (shim; convert with `vshell theme migrate`) |
| Imported colors | `vshell theme import-colors <colors.toml>` |
| Wallpaper extraction | `vshell theme extract-wallpaper <image>` transient by default; add `--save` or use `save-current` to persist |
| Manual palette edits | `vshell theme apply-colors --set role=#rrggbb` transient by default; `--persist` writes the merged palette into the theme's overlay `colors.toml` |
| Whole-palette restyle | `vshell theme restyle [--brightness/--vibrancy/--contrast/--temperature -100..100 --hue -180..180 \| --reset]` stored in overlay `theme.json.adjustments`; `--preview` writes only live shell state for QML feedback and does not persist overlay adjustments, app targets, hooks, or `theme-current.json` |
| Per-app color overrides | `vshell theme app-colors <app> --set role=#rrggbb` stored in overlay `app-colors.toml` |

Theme packages own colors, wallpapers, and curated/generated app theme files.
They do not own shell or compositor geometry such as corner radius, border size,
or spacing; those live in VGS settings.

Release bundles install the complete built-in wallpaper and icon assets. The
installer supports `VGS_THEME_BUNDLE=all|core|extras` and defaults to `core`, so
a packaging recipe that forgets the variable ships too little rather than the
full `all` bundle (sized in `packaging/README.md` § Theme bundles, which owns
that figure). The Arch, Debian, Fedora, and Void packages use `core` for
the base package (the `coppernight` default theme and targets) and `extras` for
the optional `vgs-shell-assets` collection of remaining themes, wallpapers, and
vendored Yaru icon assets; Gentoo folds `extras` into `USE=extra-themes` and the
Nix flake asks for `all`. The base package remains fully functional; install the
asset package to restore the complete built-in collection. Bundle assignments per
channel are tabulated in `packaging/README.md`. The base package also ships the
download catalog and every theme's screenshot so the rest stay discoverable —
see "Theme download catalog" below.

## Theme package format
A theme is a directory, not a single JSON:

```
themes/tokyo-night/
  theme.json      # metadata: name, mode (dark|light), pair, source (curated|generated),
                  # optional "wallpaper" (default background filename; else first
                  # alphabetical) and "hiddenBackgrounds" (user-overlay list that
                  # filters built-in wallpapers out of the composed set)
  colors.toml     # base palette (22-key set)
  backgrounds/    # wallpaper set; composed file-level across builtin + user overlay
  preview.png     # optional committed screenshot (else preview generator runs)
  apps/           # optional curated per-app configs — these WIN over generation
```

Compose rules: the user directory overlays the built-in one
file-by-file (user file wins). For every app target without a curated
`apps/<file>`, the template under `themes/targets/<id>/` renders from
`colors.toml` roles. Curated files install verbatim (only `{wallpaper}`-style
path tokens render). Target `config.json` maps curated files via `app`,
`curatedFile`, and optional `curatedDestination`/`curatedMode: additional`
(curated artifact lands beside the generated one, e.g. nvim colorscheme spec).

Optional `curatedThemeFile` names a full *theme* file that a package ships to
**replace** the generated template output at the main `destination` (rather than
a pointer landing at `curatedDestination`). Every theme uses this for VS Code:
`apps/vscode-theme.json` (the official theme where one exists, else one derived
from the nvim highlight colors), which the local `vgs.vgs-theme` extension loads
verbatim instead of the palette-generated theme. Present `curatedThemeFile` →
template skipped for that destination; absent → template renders as usual.

## User-overlay edits (safe editing of built-in themes)
All in-settings color edits are ordinary user-overlay files under
`~/.config/vshell/themes/<name>/`, so built-ins stay pristine in the repo and
`vshell theme revert <name>` just deletes the overlay directory:

- `colors.toml` (overlay) — persisted per-role edits. `vshell theme apply-colors
  --persist [--set role=#hex ...] [--name <theme>]` merges the edits over the
  theme's base palette and writes the full 22-key file (source preserved: curated
  stays byte-exact, no contrast rewrite), then re-applies.
- `theme.json.adjustments` (overlay) — optional `{brightness, vibrancy, contrast,
  hue, temperature}` restyle object (ints; b/v/c/temp -100..100, hue -180..180, 0
  neutral). Non-destructive: the pipeline is compose `colors.toml` → apply persisted
  edits → apply the perceptual OKLab/OKLCH adjustment transform to the 22 base
  colors → derive roles,
  so the stored `colors.toml` is never rewritten and an all-zero object is a
  byte-exact no-op. `vshell theme restyle` writes it (omitting the key when all
  zero, dropping a now-identical overlay `theme.json` so the theme reads unmodified).
  Note: restyling a built-in snapshots its whole composed `theme.json` into the
  overlay (required so `mode`/`pair`/`wallpaper`/`source` survive reload under the
  file-level overlay). Consequence: later repo edits to that built-in's `theme.json`
  are masked until the overlay is dropped (`restyle --reset` back to neutral, or
  `theme revert`).
- `app-colors.toml` (overlay) — `[<app>]` tables of `role = "#hex"` per-app
  overrides, merged over the derived role map for that app's target only at render
  time. `vshell theme app-colors <app> [--set role=#hex ... | --reset]` edits it and
  re-renders just that target (+ hook); `vshell theme app-roles <app> --json` lists
  the roles the app's template consumes (`{roles:[{role,value,overridden}],
  curated}`; curated-file apps with no generated template report `{roles:[],
  curated:true}`).

Applied-state JSON gains: `theme current --json` → `modified` (built-in with any
user overlay file), `builtin`, and `adjustments`; each `theme list --json`
blueprint entry → `modified`, `adjustments`, and `appOverrides` ({app: count}).

## Curated vs generated palettes
`source: curated` themes pass ANSI + extended colors through untouched — no
contrast rewriting anywhere in the pipeline; only missing roles (surface
ladder, status/container roles) are derived. `source: generated` palettes get
role normalization + contrast enforcement (`ensure_contrast`,
`stabilize_ansi_role_pairs`). Lossy mode transforms always downgrade the
result to `generated`. `vshell theme lint [name]` reports contrast warnings
for curated palettes instead of rewriting them.

## Current state
| File | Role |
|------|------|
| `~/.config/vshell/theme.json` | Current normalized theme state for QML |
| `~/.config/vshell/generated/` | Small generated helper outputs |
| `~/.config/hypr/vgs/layout.lua` | Current Hyprland layout/shape settings output, generated from VGS settings and included by dotfiles |
| `~/.config/niri/vgs/` | Current Niri colors, layout, outputs, cursor, keybind, and window-rule KDL fragments |

All built-in packages ship `preview.png`. Preview generation for a new user
package remains an optional development-only nested-Hyprland workflow; it is
not part of the Niri runtime dependency set.

## Apply flow
1. User chooses a theme, wallpaper, or imported colors.
2. QML calls `vshell theme ...` through `Paths.vshellCli`.
3. `bin/vshell` dispatches to `bin/vshell-helper`.
4. Helper resolves the theme dir (user overlays built-in, per file) and reads `theme.json` + `colors.toml`.
5. Roles: passthrough for curated themes; normalize + contrast enforcement for generated ones.
6. For each app target: curated `apps/<file>` installs verbatim, else the template renders from roles.
7. Helper writes `theme.json` (+ `theme-current.json`).
8. Reload/setup hooks connect generated fragments to their consumers and refresh apps or services.
9. QML theme service reloads current theme.

## Per-app toggles
`themeApps` in settings.json (`{ "kitty": true, "foot": false, ... }`) gates
which targets render on apply. Absent key = default from app detection
(`detect.commands`/`detect.paths` in the target's config.json). `app: shell`
targets always render. Toggling OFF stops updating outputs (last render stays
in place — VGS never deletes shared paths like `gtk.css`); toggling ON via
`vshell theme apps --enable <app>` re-renders just that app for the current
theme. CLI: `vshell theme apps [--enable <app>|--disable <app>] [--json]`.
QML UI reads `VGSThemeService.themeApps` and toggles via
`VGSThemeService.setAppEnabled()`, which updates the persisted
`SettingsData.themeApps` map and re-renders the app when enabled. Settings
migration v12 replaced the legacy `matugenTemplate*` app-toggle keys.

## Generated targets
Stable contract: consumers may depend on these paths.
Rename only with compatibility shim.

| App | Output |
|--------|--------|
| Hyprland | `~/.config/hypr/vgs/colors.lua` (+ curated snippet `~/.config/hypr/vgs/theme.conf`); settings-owned shape/layout output lives separately at `~/.config/hypr/vgs/layout.lua` |
| Niri | `~/.config/niri/vgs/colors.kdl`, with an idempotent managed include in `config.kdl`; settings-owned shape/layout, output, keybind, cursor, and window-rule fragments live beside it under `~/.config/niri/vgs/` |
| Ghostty | `~/.config/ghostty/themes/vgs` |
| Alacritty | `~/.config/alacritty/vgs.toml` |
| Kitty | `~/.config/kitty/vgs-theme.conf`; VGS preserves `kitty.conf`, adds the include once, then SIGUSR1-reloads running instances |
| Foot | `~/.config/foot/vgs-theme.ini`; VGS preserves `foot.ini`, adds the include once, and retains the effective system config when it must create a new user config |
| WezTerm | `~/.config/wezterm/vgs-theme.lua` |
| tmux | `~/.config/tmux/vgs-theme.conf` or dotfiles-linked target |
| Neovim | role table `~/.local/share/vshell/theme.nvim.lua` (always) + curated colorscheme spec `~/.local/share/vshell/theme.nvim.spec.lua` (curated themes only; removed when absent). The VGS nvim bridge (`config/vshell/nvim/vgs-theme-bridge.lua`, dofile'd from the user's nvim config) loads the current theme's colorscheme from the spec: `vgs_vendored` plugins resolve to `config/vshell/nvim/colorschemes/<dir>` and load by directory (no network), preserving each spec's `opts`. Because lazy runs `setup()` once, the bridge re-runs `setup(opts)` on every reload so a live switch re-colors. Inline-function colorschemes are invoked directly; failing both, base16 highlights from roles, else terminal ANSI. Live switch via the file watcher; a not-yet-loaded plugin needs an nvim restart. Preview generator uses the same logic |
| btop | `~/.config/btop/themes/vgs.theme`; hook SIGUSR2-reloads running instances |
| Helix | `~/.config/helix/themes/vgs.toml` |
| VS Code family | `~/.config/vshell/generated/vscode/vgs-theme.json`; hook covers detected variants (VS Code/Code-OSS/VSCodium/Cursor). Every theme ships a bundled `apps/vscode-theme.json` (no marketplace pointer). The local `vgs.vgs-theme` extension, registered in the variant's `extensions.json`, contributes **every bundled theme up front** under its own label (from the theme JSON `name`). A running editor cannot learn a theme added after launch, so registering all of them avoids a stale-label no-op — one full editor restart is needed after install, then switches are live. A switch just rewrites `workbench.colorTheme`, which VGS drives whenever the live theme is VGS-owned (a foreign, user-picked theme is left alone) |
| Zed | `~/.config/zed/themes/vgs.json` |
| Emacs | `~/.config/emacs/vgs-theme.el` |
| KDE colors | `~/.local/share/color-schemes/Vgs.colors` |
| Icons | curated `icons.theme` pointer → `~/.config/vshell/generated/icons.theme`; hook gsettings-applies it unless VGS settings manage icon themes. Yaru icon themes (+ accent variants) are vendored under `config/vshell/icons/` (see its `ATTRIBUTION.md`); `ensure_bundled_icon_themes` symlinks them into `~/.local/share/icons` on apply/enumeration so pointers resolve without a system `yaru-icon-theme` install (a real system/user install of the same name wins) |
| fastfetch | `~/.config/vshell/generated/fastfetch/logo.jpg` (theme logo, centre-cropped from the theme wallpaper role when Pillow, ImageMagick, or ffmpeg is available; otherwise that wallpaper is copied without conversion). When fastfetch is installed and no effective user/system config exists, VGS seeds a terminal-protocol-auto-detecting boxed image-logo layout at `~/.config/fastfetch/config.jsonc`; existing configs anywhere in Fastfetch's search path are never shadowed or replaced. |
| Discord clients | `~/.config/vesktop/themes/vgs-discord.css`, `~/.config/Vencord/themes/`, `~/.config/equibop/themes/` (user enables the theme once in-app) |
| Zen Browser | `~/.config/vshell/generated/zen/userChrome.css` (user imports into their zen chrome dir) |
| Pywalfox | `~/.cache/wal/colors.json`; hook runs `pywalfox <mode>` + `pywalfox update` |
| Obsidian | `~/.config/vshell/generated/obsidian.css`; hook installs a "VGS" theme into every registered vault |
| Pi | `~/.pi/agent/themes/vgs-theme.json` |
| Claude | hook updates `~/.claude/settings.json` `theme` to `light-ansi`/`dark-ansi` |
| GTK | `~/.config/gtk-3.0/gtk.css`, `~/.config/gtk-4.0/gtk.css`; hook sets GNOME `color-scheme` and GTK theme for light/dark libadwaita apps |
| Qt | `~/.config/qt6ct/colors/vgs.conf`, `~/.config/qt5ct/colors/vgs.conf`; VGS preserves qtct settings while selecting the generated palette and enabling `custom_palette` |
| Chromium helper | `~/.config/vshell/generated/chromium.rgb` |
| Shell | `~/.config/vshell/theme.json` |
| Greeter sync | `/var/cache/vshell-greeter/theme.json` plus per-user `users/<name>/theme.json` |

## Template tokens
Target templates use role tokens from normalized palette data.
Examples:
```text
{background}
{background.strip}
{background.rgb}
```

## Wallpaper commands
```bash
vshell theme set-wallpaper <path>
vshell theme set-wallpaper <path> --extract --mode auto|light|dark
vshell theme save-current --name <name>
vshell theme clear-wallpaper
vshell theme wallpapers [<name>]                    # composed set: origin, default flag
vshell theme wallpaper-add <path> [--theme <name>]  # copy into the user overlay
vshell theme wallpaper-remove <file> [--theme <name>]  # delete user file / hide built-in
vshell theme wallpaper-default <file> [--theme <name>] # sets "wallpaper" in overlay meta
```

Wallpaper-set notes: `wallpaper-remove` deletes user-overlay files and hides
built-ins via the overlay `hiddenBackgrounds` list; removing the default clears
the overlay `wallpaper` key. Adding/removing non-default wallpapers does not
invalidate theme previews (the preview hash sees only the default wallpaper).
`WallpaperCyclingService` cycles the composed set (helper order) when the
current wallpaper belongs to the active theme, else scans its directory.

The `wallpaperSource` setting (`theme`|`folder`) decouples wallpapers from
theme applies: under `folder`, `MethodTheme.parseTheme()` and
`VGSThemeService.applyBlueprint()` skip the session wallpaper sync (the helper
still records the theme default so previews/roles keep working) and the user's
`wallpaperFolder` drives the browser and cycling. The dash Themes tab surfaces
the policy as a "Use theme wallpapers" toggle (same setting as the Settings →
Wallpaper card), and theme-apply toasts note when the wallpaper was kept.

`SessionData.setWallpaper/setWallpaperColor/clearWallpaper/setModeWallpaper`
propagate to every monitor when per-monitor mode is on — the global path is
not displayed in that mode, so without propagation theme applies and browser
clicks would change nothing visible. Single-screen assignment stays explicit
via `setMonitorWallpaper` (the per-monitor buttons in the wallpaper browser).

Without `--extract`, wallpaper changes preserve current theme name and colors.
With `--extract`, helper generates and applies a transient palette without writing anything. `--save` (or `save-current`) materializes a full v2 theme package under `~/.config/vshell/themes/<name>/`: `theme.json` (`source: generated`), `colors.toml`, the wallpaper in `backgrounds/`, and an editable rendered `apps/<file>` for every toggled-on app. Users tweak `apps/<file>` and re-apply; re-deriving from the palette is explicit via `vshell theme regenerate <name> [--app <id>]` (refuses to overwrite hand-edits without confirmation), never implicit on apply.

## Light/dark mode and pairing
Themes carry `mode` (`dark`|`light`) and an optional `pair` naming the counterpart theme in the other mode (e.g. `tokyo-night` ↔ `catppuccin-latte`) in `theme.json`. User themes that shadow a builtin by name inherit the builtin's `pair`.

`vshell theme mode <light|dark|toggle>` semantics:
1. Already in the target mode → no-op.
2. Current blueprint has a pair (explicit `pair`, or `-dark`/`-light`/`-day` name conventions) whose mode matches → apply it.
3. Otherwise the theme picker opens filtered to the target mode — the helper never invents a palette. `--transform` restores the old lossy palette transform for scripting.

## Theme and wallpaper browsing (dash tabs)
Browsing lives in the bar's center dash dropdown (`Modules/Dash/DashPopout.qml`):
- **Themes** tab (`Modules/Dash/ThemesTab.qml`): search, All/Dark/Light chips, screenshot previews with an overlay Apply pill, per-theme actions.
- **Wallpapers** tab (`Modules/Dash/WallpaperTab.qml`): thumbnail grid over the current theme's composed set or the user's wallpaper folder; Apply pill, default/per-mode/per-monitor assignment, add/remove, palette extraction.
- Tab order/visibility: `dashTabs` setting (Settings → Dash).
- IPC target `theme-picker` (`open`, `openMode <mode>`, `openWallpapers`, `close`, `toggle`) is a compatibility shim onto the dash tabs, keeping Super+T, the VGS menu, and `vshell theme pick [all|dark|light]` working.
- Data: `VGSThemeService.blueprints` (`vshell theme list --json`: `mode`, `pair`, `preview`, `backgrounds`, `defaultWallpaper`) + `VGSThemeService.themeWallpapers` (`vshell theme wallpapers --json`).
- Thumbnails: shared `~/.cache/vshell/imagecache/` disk cache, pre-generated in one batched `ffmpegthumbnailer` run by `Widgets/WallpaperThumbnailPreloader.qml` (mtime-aware; optional `thumbnails` dependency).
- Long helper calls (preview rendering) run as background tasks in `VGSThemeService`; Apply buttons never block.

## Preview screenshots
`vshell theme preview [name|--all] [--force]` renders a real screenshot per blueprint: a nested Hyprland session runs ghostty+nvim (theme-driven highlights, mock neo-tree/statusline), a second ghostty showcase, the installed file manager (dolphin > nautilus > thunar) with an isolated `XDG_CONFIG_HOME` and a synthetic `HOME` (a fixed sample tree — the pane must not vary per machine or carry real filenames into a committed screenshot), and a minimal Quickshell bar+control-center replica (`quickshell/vshell-preview/shell.qml`).

Mechanics (Hyprland native-Lua config and `hyprctl`):

- The nested preview compositor is launched with a transient native-Lua
  `hyprland.lua`; VGS does not generate the legacy `.conf` format removed in
  Hyprland 0.57.
- The parent stages a headless output `VGSPREVIEW` (scale 1) plus a runtime `hl.window_rule` (via `hyprctl eval`) that parks `aquamarine` (nested-compositor) windows there fullscreen without focus. Runtime rules cannot be removed individually and a config reload disturbs the session, so the rule is left in place — the routine hypr-reload hook on theme apply flushes it.
- Every preview is exactly `PREVIEW_SIZE` (1920x1080). Gaps, border width and any reserved bar area are user config, so the staging output is *created* that much larger (`preview_stage_chrome()` + measured reserved) and the nested session lands on the target size; window geometry is baked into the nested config's exec rules from the same fixed canvas. A capture that comes out at another size is retried once and logged — shipped previews cannot vary with local Hyprland settings.
- The parent must keep rendering the headless output or the nested session's render callbacks stall; the generator pumps it with `grim -o VGSPREVIEW` while waiting.
- Capture runs inside the nested session (`theme preview-capture`), then the compositor exits. Cursor/focus and workspace assignment are saved/restored around output add/remove.
- The live shell excludes `VGSPREVIEW` from all per-screen surface models (`SettingsData.usableScreens()`), so it never draws bar/wallpaper/notification surfaces on the transient output — removing it would otherwise kill the shell's Wayland connection.

Cache: `~/.cache/vshell/theme-previews/<name>-<hash>.png`, hash over palette + wallpaper + curated `apps/` file mtimes + generator version. The picker triggers `vshell theme preview --all` in the background when previews are missing.

Every built-in theme ships a committed `themes/<name>/preview.png`, so a fresh
install shows a full theme browser without generating anything. Resolution order
in `theme list --json`: cached screenshot → committed `preview.png` → missing
(triggers generation). The committed shot is *skipped* once the user has
overlaid or restyled that theme (`modified`, or non-zero `adjustments`), because
it no longer shows what applying the theme would do — those regenerate as before.
User themes under `~/.config/vshell/themes/` never write into the repo.

## Theme download catalog
Packages ship the `core` bundle, i.e. one theme, so browsing installed themes on
a fresh install browses a single entry. `themes/catalog.json` is the discovery
path for the rest:

```bash
vshell theme catalog list [--json]                 # every published theme + installed state
vshell theme catalog install <name>... [--force]   # download into ~/.config/vshell/themes/<name>/
vshell theme catalog install --all                 # everything not installed (size: .totalSize in themes/catalog.json)
vshell theme catalog remove <name>...              # only themes this catalog downloaded
```

- The manifest is generated by `scripts/gen-theme-catalog.py --write` and
  committed. It carries each theme's mode, pair, palette and per-file
  `{path, size, sha256}`, plus `source.refs`: the pinned release tag **and** the
  moving `main` ref, tried in order. Two locations are needed because the
  checksums come from the working tree while the tag is fixed at release — a
  theme edited after the tag is served correctly only by `main`, which is what a
  `vgs-shell-git` install off trunk needs. This weakens nothing: the committed
  size and sha256 remain the sole authority, so a location serving other bytes is
  rejected rather than trusted, and a file no location can satisfy fails loudly
  naming every location tried.
- Two guards, each proving something a ref-string comparison cannot:
  `scripts/gen-theme-catalog.py --check` (run by
  `scripts/check-package-assets.sh`, so on every PR) regenerates the manifest and
  then compares the tree against the pinned ref with git, failing when the
  content differs and no moving ref is declared — i.e. when the catalog describes
  content nothing can serve. `--check-release-pin <version>` (run by
  `scripts/check-release.sh`) additionally requires `source.ref == v<version>`
  and a fully committed `themes/`, because the tag a release creates captures the
  commit, not the working tree.
- `core` also installs every theme's screenshot as
  `themes/catalog-previews/<name>.png` (~23 MiB), so the browser shows themes it
  has not downloaded. `all` needs none of that (each theme carries its own
  `preview.png`); `extras` ships neither. `catalog-previews` is a reserved theme
  subdirectory, never a package.
- Downloads are ordinary user theme packages under
  `~/.config/vshell/themes/<name>/`, applied through the same path as built-ins,
  and marked with a `.vgs-catalog.json` file recording the theme's name and its
  own path. Ownership for `catalog remove` is that identity, not the marker's
  presence: `theme duplicate` copies a package wholesale, so a copy inherits the
  marker and a presence test would delete the user's own theme. Removal is
  likewise refused for a hand-made theme and for the currently applied theme,
  and the settings browser asks for confirmation first.
- Downloads deliberately run *outside* the theme mutation lock — an
  `install --all` is a gigabyte-scale transfer (the exact figure is
  `.totalSize` in `themes/catalog.json`), and holding the exclusive lock for
  that long would block theme applies, the light/dark keybinding, wallpaper
  changes and restyles for hours. The lock is taken only around the directory
  swap that publishes a staged theme (and the rename in `catalog remove`), which
  is the only step that mutates theme state.
- Fetch rules: https only (a `file://` base URL is accepted solely from the
  test-only `VGS_THEME_CATALOG_BASE_URL` override), every file checked against
  its committed size and sha256 before it leaves a staging directory, only the
  closed set `theme.json`/`colors.toml`/`preview.png`/`apps/*`/`backgrounds/*`,
  and nothing downloaded is ever executed. Python stdlib does the fetching, so
  the feature adds no external command dependency.
- QML side: `Services/VGSThemeCatalogService.qml` (thin front over the CLI) and
  `Modules/Settings/ThemeCatalogBrowser.qml`, opened by **Download More Themes**
  on the Themes settings tab.

## Chromium policy
Command:
```bash
vshell theme chromium-policy
```

Writes direct when permitted; otherwise needs local privilege wrapper/enablement.

## Deliberately not themed
Verified against reference shell/theme projects (2026-07):
mangowc, upstream-only helper tools, spicetify
(not in either upstream anymore), firefox userchrome (pywalfox covers Firefox),
mako/swayosd/walker/waybar/hyprlock (VGS ships its own equivalents),
gum and keyboard.rgb (niche upstream extras; revisit on request).

## Rules
- Add target output by adding `themes/targets/<id>/config.json` and templates.
- Use semantic roles (`foreground`, `statusFg`, `groupbarInactiveFg`, `onPrimary`) instead of assuming ANSI colors have a fixed light/dark meaning.
- Do not add shell/compositor geometry tokens to generated app targets. GTK target intentionally avoids app-wide radius so terminal/app interiors stay square unless app-owned styling says otherwise.
- Hyprland window radius, border size, and Quickshell surface shape are VGS settings, not theme package fields or generated app CSS.
- Keep generated output paths VGS-named.
- Keep role derivation in helper code, not QML.
- Keep QML as UI/orchestration only.
- Treat generated paths as product API.
