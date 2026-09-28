# V2 audit against the latest Omarchy

VGS-495. This report compares everything V2 has shipped with how the latest Omarchy solves the same problem, area by area, and gives each area a verdict.

- VGS: `origin/main` at `513cc411` (2026-09-28), which includes VGS-491, VGS-493 and VGS-494.
- Omarchy: `basecamp/omarchy` `main` at `b18ab49` (version `4.0.0.alpha`), read from a read-only clone.
- Quickshell: `0.3.1` source at `1a4716c`, read only to confirm the session-lock reload behaviour in § IPC, CLI and runner.

## Research question

For each area VGS has built, which is simpler and more robust: what VGS does, what Omarchy does, or a third design? The owner's bar is simple, clean and elegant, with no over-engineering. Omarchy is a reference, not a constraint.

## Verdicts

- **keep**: the VGS approach is as good as Omarchy's or better.
- **adopt**: take Omarchy's approach.
- **third way**: neither is best, and a smaller design exists.

Each adopt and third-way finding is posted as one `Proposal:` comment on VGS-495 for the overseer to file.

## Summary

Omarchy 4 now ships its own Quickshell shell. It has manifest plugins with the kinds `bar-widget`, `bar`, `panel`, `overlay`, `menu` and `service`, a JSON `shell.json` with a `bar.layout` list, a git plugin manager and a template-driven theme pipeline. The two designs have converged. VGS's core is stricter everywhere Omarchy relies on convention: one manifest judge, declared capabilities, a lock-holder guard, a merged two-layer configuration, a single checked dispatch path, a watched shell file instead of IPC pushes, and a nested sandbox in place of tests on the live seat. Most areas are keep.

The findings that change something:

| # | Area | Verdict | Change | Priority |
|---|---|---|---|---|
| 1 | Runner | adopt | Turn Quickshell's file watcher off in `vgsh run`; a reload while locked unlocks the session | 2 |
| 2 | Runner | adopt | Add `vgsh restart`, refused while the session is locked | 3 |
| 3 | Theme toolkits | adopt | Set GTK's `color-scheme` from `scheme.mode` on every apply | 3 |
| 4 | Theme trust | adopt | Render templates instead of a cloned theme's hand-written files for targets whose files run code | 3 |
| 5 | Backgrounds | adopt | Decode the wallpaper at device pixels, not logical pixels | 3 |
| 6 | Bar | adopt | Ship the clock and workspaces as bar-widget plugins in the default `bar.layout` | 3 |
| 7 | Plugin-owned looks | third way | Move the launcher's and notifications' copied glass primitives into `qs.Ui` as look-parameterised components | 3 |
| 8 | Plugin manager | adopt | Confirm after the diff in `vgsh plugin update`; refuse without a terminal unless `--yes` | 3 |
| 9 | Theme targets | adopt | Read user targets from `~/.config/vgs/themes/targets/` | 4 |
| 10 | Theme packages | third way | Derive the sixteen terminal slots from the palette when a package ships no `terminal.json` | 4 |
| 11 | Backgrounds | third way | Pick a specific wallpaper from thumbnails in the themes panel's Wallpaper section | 4 |
| 12 | Plugin model | adopt | Rescan when a file under the user plugin directory changes | 4 |
| 13 | Plugin manager | third way | `vgsh plugin clone <id>` copies a bundled plugin under the same id | 4 |

## Theme packages

**Omarchy.** A theme is `themes/<name>/`, overlaid by `~/.config/omarchy/themes/<name>/`. Its core is a flat `colors.toml` of about 27 keys: `mode`, `accent`, a background ramp, a foreground ramp and named colours (`docs/theming.md` § `colors.toml`). Templates derive the sixteen terminal colours from those names, for example `default/themed/kitty.conf.tpl`. A theme may also ship a hand-written file for any application, `shell.toml`, `icons.theme`, `backgrounds/`, preview images and `keyboard.rgb`. Light or dark comes from `mode`, else a legacy `light.mode` file, else a guess from the background's luminance (`bin/omarchy-theme-set-gnome`). 22 themes ship.

**VGS.** A theme package is `themes/<name>/theme.json`, a judged override of the token table in `shell/Commons/Tokens.js`, with an optional `terminal.json` of sixteen slots, hand-written `targets/<destination>` files and `backgrounds/` ([themes.md](../architecture/themes.md), [D019](../decisions/D019-theme-packages-carry-plugin-trust.md)). `ThemeLogic.acceptPackage` judges every package. The theme states `scheme.mode`; nothing guesses it. Two packages ship, `vgs` and `light`.

**Verdict: keep, with one third-way fix (finding 10).** VGS's document is judged, states its mode and derives shades once in the token table, where Omarchy recomputes them in each template. Omarchy's one sharp advantage is that a palette alone yields terminal colours. VGS falls back to the shipped `vgs` package's terminal slots when a package has none (`terminalSource` in `bin/lib/theme-render.js`), so a light third-party theme without `terminal.json` paints dark terminals. The fix is small: when a package ships no `terminal.json`, derive the slots from the resolved palette (`background`, `foreground`, `danger`, `success`, `warning`, `info`, `accent`, with the bright row mixed toward the foreground), and keep `terminal.json` as the override. The shipped `light` package carries its own slots, so no shipped theme is affected today.

## Theme apply

**Omarchy.** `bin/omarchy-theme-set` (451 lines) takes a `flock`, copies the shipped theme and the user's overlay into `~/.local/state/omarchy/current/next-theme`, renders templates, then runs `rm -rf current` and `mv next-theme current`. It writes `theme.name` and pushes the colours and `shell.toml` to the running shell as base64 over IPC (`shell applyTheme`). The shell's colour readers do not watch their files (`shell/Commons/Color.qml`), so without that IPC call a running shell keeps the old theme until it restarts. The swap has no rollback, and for a moment no theme directory exists.

**VGS.** `vgsh theme apply` renders every enabled target in memory, stages each write beside its destination, swaps the state directory with a rollback, keeps each include line and settings key, and writes the shell document `~/.config/vgs/theme.json` last ([theme-apply.md](../architecture/theme-apply.md), [D020](../decisions/D020-theme-apply-swaps-state-and-writes-the-shell-file-last.md), [D021](../decisions/D021-theme-apply-writes-beside-each-destination.md)). The shell watches that one file through `WatchedFile` (`shell/Commons/ThemeSource.qml`). `vgsh theme` never contacts the shell.

**Verdict: keep.** A watched file needs no IPC and no encoding, works when the shell is not running, and restyles the shell only after every application file is in place. Omarchy needs the IPC push mainly to time its wallpaper wipe with the palette change (§ Backgrounds).

## Theme targets and templates

**Omarchy.** 19 templates in `default/themed/*.tpl`, rendered by one awk pass in `bin/omarchy-theme-set-templates` (453 lines) with `{{ key }}` placeholders and a few helpers. An unknown placeholder stays in the output as literal text. About 13 more applications have their own `bin/omarchy-theme-set-*` script. Omarchy ships the application configs, so the include line is already in them (`config/kitty/kitty.conf`, `config/alacritty/alacritty.toml`). A user template in `~/.config/omarchy/themed/*.tpl` themes an application Omarchy does not ship, and replaces a built-in template with the same output name.

**VGS.** 35 targets, one directory each under `themes/targets/<app>/`, with `target.json` and templates ([theme-targets.md](../architecture/theme-targets.md)). The renderer (`bin/lib/theme-render.js`) takes `@{token.path}` and terminal placeholders, encoders and choice cases, and refuses a target with an unknown placeholder; validation checks every template offline. Wiring is one of three forms, each asserted on every apply and removed when the target is disabled: an include line ([theme-wiring.md](../architecture/theme-wiring.md)), managed links ([D022](../decisions/D022-theme-apply-keeps-managed-links-in-application-directories.md)) or one settings key ([D024](../decisions/D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md)). The judge reads targets only from the shipped directory.

**Verdict: keep the mechanism, adopt the user target slot (finding 9).** VGS does not own the user's dotfiles, so it must assert its wiring; Omarchy can skip that because it ships them. Declarative, judged targets beat per-application scripts and silent placeholders. What VGS lacks is Omarchy's path for an application VGS does not ship. Read `${XDG_CONFIG_HOME}/vgs/themes/targets/<name>/` as well, judged by the same `acceptTarget`, with a shipped target winning a name collision. [themes.md](../architecture/themes.md) already reserves the name `targets` in the user theme directory.

## Reloads after apply

**Omarchy.** One fixed list, `post_theme_commands` in `bin/omarchy-theme-set`, of 17 commands run in parallel after the lock is released, with every error ignored. The commands touch or signal each application (`SIGUSR1` kitty, `SIGUSR2` ghostty, btop and opencode), recolour open foot and tmux panes with OSC escapes, and run `hyprctl reload` on every apply. A user `theme-set` hook runs last.

**VGS.** Each target declares its own `reload` command and timeout. A hook runs only when the target's bytes changed, when its last run failed, or when the target sets `always`. A failure is recorded in `reload-pending.json` and retried by `vgsh theme reload`. Signals are scoped to the user and the exact process name. Hooks run one at a time under the theme lock (`bin/vgsh-theme-judge`, the `spawnSync` loop).

**Verdict: keep.** Per-target hooks, change-only runs and a retry record are more robust than a central list whose failures vanish, and they avoid an unconditional `hyprctl reload`. Two notes, neither a proposal. Serial hooks hold the theme lock for their total time, where Omarchy releases its lock before retinting; measure it before changing it. Open foot windows keep the old colours because the foot target has no hook, and Omarchy's OSC recolour is the known fix if that matters.

## Theme install, update, remove and trust

**Omarchy.** `bin/omarchy-theme-install` checks the URL against a transport allowlist (`bin/omarchy-git-url-check`), deletes any existing theme directory of the same name, clones, and applies the theme at once. `-update` pulls every cloned theme. At staging, `omarchy-theme-set` drops from a cloned theme (one with a `.git` directory) every file that can run code: any `*.lua`, the four terminal configs, `vscode.json` and every symlink (`INSTALLED_THEME_DENIED`, `docs/theming.md` § What an installed theme may not ship). Templates render those files instead. A test fails when a new template is classified as neither code nor colour.

**VGS.** `vgsh theme add` clones into staging with hooks off and no submodules, judges the package, names it from `theme.json` and refuses an existing name; `update` fast-forwards only and rolls back a version the judge refuses; `remove` deletes only an installed directory. None applies the theme. A package's hand-written target file is written byte for byte for every target (`renderTarget` in `bin/lib/theme-render.js`), including files other programs execute: `hyprland.conf`, `neovim.lua`, `wezterm.lua`, `emacs.el` and `kitty.conf`. [D019](../decisions/D019-theme-packages-carry-plugin-trust.md) gives packages plugin trust on purpose.

**Verdict: keep the mechanics, adopt the trust filter (finding 4).** VGS's install is strictly safer than Omarchy's: no `rm -rf` of a same-name theme, fast-forward only, a rollback. But D019 means a theme someone shares can run code at login or when an editor starts, and a theme is the thing users install most casually. Omarchy's rule costs one list and one check. Add a `target.json` flag marking targets whose files load or run code (hyprland, neovim, wezterm, emacs, kitty, foot, alacritty, ghostty, tmux, vscode), and render the template instead of an installed package's hand-written file for those targets, naming the dropped file. Shipped packages stay trusted. This supersedes the trust part of D019, so it needs a decision record.

## Light and dark mode for toolkits

**Omarchy.** `bin/omarchy-theme-set-gnome` sets `org.gnome.desktop.interface color-scheme` to `prefer-light` or `prefer-dark`, `gtk-theme` to `Adwaita` or `Adwaita-dark`, and `icon-theme`. Qt follows GTK through `QT_QPA_PLATFORMTHEME=gtk3` (`default/hypr/envs.lua`). Omarchy ships no GTK or Qt colour stylesheet.

**VGS.** The `gtk3` and `gtk4` targets import rgba CSS that sets adw-gtk3 and libadwaita colours; `qt5ct`, `qt6ct` and `kcolorscheme` link colour schemes; `icons` sets `icon-theme` on every apply ([theme-toolkits.md](../architecture/theme-toolkits.md)). No target sets `color-scheme`: no file under `themes/`, `bin/` or `docs/` names it.

**Verdict: adopt (finding 3).** VGS paints far more of each toolkit than Omarchy, but libadwaita applications, the portal's `prefers-color-scheme` that browsers and Electron apps read, and GTK's own dark variant all start from `color-scheme`. A light theme can therefore be painted over widgets an application drew for dark mode, and the reverse. Add a target shaped like `icons`: no wiring, `always`, a hook that sets `color-scheme` to `prefer-<scheme.mode>` and skips the write when the value already holds.

## Backgrounds

**Omarchy.** The current image is the symlink `~/.local/state/omarchy/current/background`. `bin/omarchy-theme-bg-next` steps through the theme's `backgrounds/` and the user's `~/.config/omarchy/backgrounds/<theme>/`; `omarchy-theme-set` remembers one image per theme. Because the theme directory is replaced on each switch, `omarchy-theme-set` hardlinks the old and new images into a transition cache and sends a `background prepare` call early. `shell/plugins/background/Background.qml` (448 lines) reads the symlink at startup and on IPC only, decodes at `width * devicePixelRatio` after probing each image's native size with `magick identify`, and runs a 420 ms masked wipe timed with the palette change. It accepts WebP and video; 79 of its 92 shipped wallpapers are WebP.

**VGS.** `bin/lib/theme-backgrounds.js` is the one writer of `backgrounds.json` and the `background` symlink, both replaced by rename. `current` points into the package's own `backgrounds/`, so nothing is copied. Since VGS-493, `vgs.themes` declares the `background` kind: `shell/plugins/vgs.themes/WallpaperState.qml` watches the JSON file ([theme-backgrounds.md](../architecture/theme-backgrounds.md) explains why a symlink watch misses changes), and `shell/plugins/vgs.themes/Background.qml` draws one `Image` per screen with `PreserveAspectCrop` and `retainWhileLoading`. It sets `sourceSize` to `screen.width` and `screen.height`, which are logical pixels.

**Verdict: keep the state and the hard cut, adopt the device-pixel decode (finding 5).** One writer and one watched file catch up even when an IPC call is lost; Omarchy's symlink is read only on IPC, and its comments claim a poll that does not exist. The wipe needs a prepare call, snapshot hardlinks, a pending-theme payload and a fallback timer across two processes, which fails the owner's bar for a cosmetic gain. The decode size is a defect: on a screen scaled 2x the wallpaper decodes at half resolution and looks soft, while the launcher and notifications already multiply by `devicePixelRatio`. Multiply `sourceSize` by `screen.devicePixelRatio`, and run the background row once at a scale above 1. Omarchy's native-size probe is not worth taking; VGS ships no oversized stock images.

## Themes panel and background picker

**Omarchy.** A key or the menu summons `omarchy.image-picker` in theme mode. `bin/omarchy-theme-switcher` (130 lines) builds a preview per theme from its hand-made `preview.png`, else its first background, and `bin/omarchy-menu-images` (382 lines) builds cached thumbnails. The picker has a filter box and keyboard navigation. Choosing a theme runs `omarchy-theme-set` and neither waits for nor shows the result. Background picking reuses the same overlay through a file round trip: the caller creates a selection file and a done file, then loops on `sleep 0.01` with no timeout until the done file exists.

**VGS.** `vgs.themes` is a bar widget and a panel on the `theme` capability. `ThemesPanel.qml` lists packages through `shell.theme.list`, with a palette swatch and state badges per row (displayed, modified, applying, shadowed, refused). The last apply's failed targets stay on the package's row, because the result lives in `ThemeRunner`. `scripts/smoke/rows/themes.sh` covers it ([theme-capability.md](../architecture/theme-capability.md)). There is no preview image, filter or default key. Since VGS-493 the panel's Wallpaper section names the current image and steps it with Previous and Next, through the `theme` capability and `vgsh theme background previous` and `next`.

**Verdict: keep the panel, third way for picking a background (finding 11).** Showing each apply's state and failures matters because a VGS apply is judged and can partly fail, and a judged swatch costs nothing to maintain where a preview screenshot is a hand-kept asset. Omarchy's round trip exists because a bash caller must read a value back from the shell; VGS has no such caller. Add `vgsh theme background list --json` and `vgsh theme background set <file>` beside `previous` and `next`, expose them on the `theme` capability, and show the applied package's images as a thumbnail strip in the Wallpaper section, each an `Image` with a small `sourceSize`. Add no generic picker and no thumbnail cache until a measurement asks for one.

## Gallery

**Omarchy.** `shell/plugins/dev-gallery/GalleryPanel.qml` (1,854 lines) draws the `qs.Ui` components with a keyboard cursor model and opens at a named section. `bin/omarchy-dev-theme-preview` prints a palette in the terminal with contrast ratios.

**VGS.** `shell/plugins/vgs.gallery/Gallery.qml` (192 lines) draws every component in every variant. [design-system.md](../architecture/design-system.md) makes a new component join it in the same change, and `scripts/smoke/rows/gallery.sh` reads its sections back and checks each example stays inside the panel.

**Verdict: keep.** The VGS gallery is a checked validation target at a tenth of the size. Omarchy's cursor model demonstrates a cross-panel keyboard standard VGS does not have.

## Bar and built-in widgets

**Omarchy.** Every bar widget is its own plugin with its own manifest, the workspaces included (`shell/plugins/bar/widgets/Workspaces.manifest.json`); 21 manifests declare `bar-widget`. Each widget's settings schema is in its manifest. Placement is one list, `bar.layout.{left,center,right}` in `config/omarchy/shell.json`, which places 14 widgets by default. `bin/omarchy-bar` (403 lines) edits it with `put`, `move`, `set`, `position` and `transparent`. The bar itself is `shell/plugins/bar/Bar.qml` (2,076 lines).

**VGS.** `vgs.bar/Bar.qml` (65 lines) draws three sections. It fills each first with its own built-ins, named in its `left`, `center` and `right` settings (`shell/plugins/vgs.bar/manifest.json`), through the `builtins` capability and `Builtin.qml`; the core then mounts plugin widgets after them from `bar.layout` ([D013](../decisions/D013-built-in-widgets-are-the-bar-plugins.md)). The shipped `config/shell.json` leaves `bar.layout` empty.

**Verdict: adopt (finding 6).** Built-ins give one bar two placement lists and a fixed order: a plugin widget can never sit left of the clock. The clock's `clockFormat` is a clock setting declared in the bar's schema, which is D013's own revisit condition ("a built-in needs its own settings schema"). Ship `vgs.clock` and `vgs.workspaces` as bar-widget plugins placed by the shipped `bar.layout`, and drop the bar's `left`, `center` and `right` settings. The manager button can stay the bar's one built-in, so the manager keeps working when every plugin widget is disabled; that keeps `builtins` and narrows D013 rather than removing it. The small VGS bar and core-mounted sections stay: Omarchy's 2,076-line bar owns position, transparency and drag reorder, which VGS has not chosen to build.

## Launcher

**Omarchy.** No separate launcher. `SUPER+SPACE` opens the `omarchy.menu` root and `SUPER+ALT+SPACE` its applications submenu (`default/hypr/bindings/utilities.lua`). Applications come from a shared service, `shell/services/AppLibrary.qml` (268 lines), filtered by `default/omarchy/launcher.hides` and `shell/services/hidden-entries.sh`. Colours come from the central `Color` singleton.

**VGS.** `vgs.launcher` is one plugin with the kinds overlay, bar widget and service, about 3,350 lines: menu, applications from `DesktopEntries.applications`, `f:` file search over an fd index, and select and input pickers over IPC ([README](../../shell/plugins/vgs.launcher/README.md)). It is a port of the owner's Spotlight launcher and owns its look under [D023](../decisions/D023-plugin-owned-appearance.md).

**Verdict: keep.** Both fold menu and applications into one overlay; the extra size is file search and the owner's glass design, both chosen. A shared application service pays off only with a second consumer. Quickshell already drops `NoDisplay` entries; Omarchy's curated hide list is listed under § Gaps.

## Menu definition

**Omarchy.** `default/omarchy/omarchy-menu.jsonc` (384 lines) merges per key with a user file (`docs/menu.md`). Actions are bash strings; `when`, `checked` and `disabled` are bash guards batched into one process per open. A user file that fails to parse drops every user entry silently.

**VGS.** `shell/plugins/vgs.launcher/menu.json` is strict JSON with `schemaVersion` and a closed key list (`MenuModel.js`). `run` is an argv list with no shell; `requires` checks that a command exists. A refused user file logs and shows a notice row while the shipped menu stays.

**Verdict: keep.** Argv and `requires` remove shell injection and the guard latency Omarchy works around, and the judge fixes the silent drop. Omarchy's guards serve a large package-install catalogue VGS does not have.

## Notifications

**Omarchy.** `shell/plugins/notifications/Service.qml` (1,107 lines) creates the notification server itself. It keeps one JSON file per live toast, moves it to `history/` on dismissal, keeps 10, and replays history as toasts; there is no centre panel. DND is a flag. `bin/omarchy-notification-send` is the sender contract.

**VGS.** The core owns the server: `shell/Core/NotificationHub.qml` (57 lines) loads it only while a plugin holds the `notifications` capability and fans each notification out ([D012](../decisions/D012-core-owns-lent-objects.md)). `vgs.notifications` (about 2,600 lines) keeps one `state.json` with 100 history entries, bounded image copies, and an inbox and history panel.

**Verdict: keep.** Owning the server in the core costs 57 lines and frees the bus name when the plugin is disabled. One store file and a real inbox cover more than Omarchy's per-toast files, with fewer moving parts. Note, not a proposal: the core's `toasts` capability is a second visual channel that only `vgs.gallery` uses among shipped plugins. It needs no notification daemon, which is its reason to exist; revisit it if no plugin takes it up.

## Plugin-owned looks and duplicated components

**Omarchy.** Every plugin draws from shared `shell/Ui` components (35 files) and the central `Color` singleton.

**VGS.** [D023](../decisions/D023-plugin-owned-appearance.md) lets a plugin own its look from its own judged table, and `scripts/check-design-tokens.py` forbids any `Theme` read other than `Theme.appearance` in such a plugin, so it cannot use the `qs.Ui` components, which read `Theme`. A plugin imports no other plugin's files. The launcher and notifications therefore each carry `Anim.qml`, `ColorAnim.qml`, `EdgeLight.qml`, `GlassSurface.qml`, `Appearance.js` and the `edgelight` shader. `Anim.qml` and `ColorAnim.qml` differ only in a comment, the compiled shader is byte-identical, `EdgeLight.qml` differs by 28 diff lines and `GlassSurface.qml` by 80.

**Verdict: third way (finding 7).** Copies drift, and `EdgeLight` and `GlassSurface` already have. D023 names the fix as its own revisit condition: a `qs.Ui` component with a parameterised form that plugins with their own look share. Add `Anim`, `ColorAnim`, `EdgeLight` with its shader, and `GlassSurface` to `qs.Ui`, each taking a `look` object instead of reading `Theme`, as the superset of both copies; point both plugins at them and delete the copies. Each plugin's `Appearance.js` stays its own.

## Plugin model

**Omarchy.** `shell/services/PluginRegistry.qml` (743 lines) accepts unknown manifest keys and warns. Trust follows location: built-ins receive host objects, third-party plugins receive hand-built facades chosen by kind (`shell/services/Plugin*Api.qml`), and only first-party manifests reach authentication. `keepLoaded: true` keeps a surface warm between summons and keeps a service, the lock among them, alive through a hot reload. `inotifywait -m -r` watches the user plugin directory, and any change unloads every panel, non-kept service and widget, clears the component cache and rescans (`shell/shell.qml`).

**VGS.** One judge, `PluginLogic.validateManifest`, refuses unknown keys, kinds and capabilities, and the scripts load the same file ([D009](../decisions/D009-one-manifest-judge-under-node.md)). A plugin names its capabilities and receives each per instance with disposers ([plugins.md](../architecture/plugins.md), [capabilities.md](../architecture/capabilities.md)). The core owns the lock, so no plugin needs `keepLoaded` to hold it. A rescan rebuilds only the plugins whose sources changed ([D014](../decisions/D014-source-revisions-are-published-snapshots.md)), but only `vgsh` install commands and `vgsh ipc call shell rescanPlugins` start one; nothing watches `~/.config/vgs/plugins`.

**Verdict: keep the model, adopt the rescan trigger (finding 12).** Declared capabilities and one strict judge give Omarchy's features with fewer implicit rules; Omarchy already runs two manifest validators that disagree (`bin/omarchy-plugin-validate` checks the entry file exists, the registry does not). VGS's per-plugin rebuild is better than Omarchy's reload-everything; its trigger is worse. Watch the user plugin directory, skipping `.git`, debounce, and call the existing `rescan()`, which already queues while busy.

## Plugin manager

**Omarchy.** Nine `bin/omarchy-plugin-*` scripts behind **Setup › Plugins**. `add` (175 lines) checks the URL, warns that plugins run unsandboxed, asks, validates and lands the plugin disabled. `update` (133 lines) shows the diff, asks "Update?", fast-forwards and rolls back a failed validation; without a terminal it refuses unless `--yes`. `clone` (168 lines) copies a built-in to `<user>.<name>` and stamps `clonedFrom`, which the registry then routes so the built-in's IPC name keeps working.

**VGS.** `bin/vgsh` holds `add`, `update` and `remove` over one scanner and one judge, with git hooks, fsmonitor and submodules off ([manager.md](../architecture/manager.md), [D007](../decisions/D007-install-runs-no-plugin-code.md)). `add` lands the plugin disabled. `update` prints the diff and fast-forwards in the same step. The manager panel in the bar draws an enable switch and a settings form built from each manifest's `schema`; install, update and remove are CLI-only. The registry scans the user directory before the bundled one and keeps the first id it sees (`shell/Core/Registry.qml`), so a user copy of a bundled plugin wins.

**Verdict: keep the mechanism, adopt the update prompt (finding 8), third way for clone (finding 13).** One judge and hook-free git are more robust than Omarchy's parallel jq walkers, and the schema-driven settings form is something Omarchy lacks. A diff that scrolls past while the fast-forward runs is not a review gate: confirm after the diff on a terminal, and refuse without one unless `--yes`. For clone, the user-first scan order already does what Omarchy's `clonedFrom` routing does: `vgsh plugin clone <vgs.id>` copies the bundled directory to `~/.config/vgs/plugins/<id>` under the same id and rescans, and `vgsh plugin remove <id>` returns to the bundled copy.

## Configuration layering

**Omarchy.** A missing user `shell.json` means the shipped `config/omarchy/shell.json` is used as it is; an existing one is used alone, with no merge (`shell/shell.qml`). The first change copies the whole default file into the user file, so new defaults reach existing users only through migrations; seven of the 133 migrations rewrite `shell.json` with jq. Two writers exist, the shell and the jq scripts.

**VGS.** [D006](../decisions/D006-two-configuration-layers.md): `PluginLogic.effectiveConfig` merges the shipped layer under the user layer, a user key replacing a shipped key whole and `plugins` merged by id ([configuration.md](../architecture/configuration.md)). The user file records only deviations. `shell/Core/Config.qml` refuses to write over a file it could not read and queues saves; `WatchedFile` closes the reload race [runtime-qml.md](../architecture/runtime-qml.md) records.

**Verdict: keep.** Merging lets shipped defaults reach users without migrations, which is most of Omarchy's migration load. Both designs replace the `bar` key whole once a user has edited it, so a widget added to the shipped bar after that edit reaches neither; that becomes worth a test when finding 6 fills the shipped layout.

## IPC, CLI and runner

**Omarchy.** `bin/omarchy` (1,093 lines) routes spaced commands to 470 `bin/omarchy-*` files. `bin/omarchy-shell` wraps IPC with a 2 s timeout, a quiet mode and a socat fast path. `bin/omarchy-launch-shell` runs `quickshell -n` under `systemd-cat` with `QS_DISABLE_FILE_WATCHER=1` and `QS_NO_RELOAD_POPUP=1`, because a reload against a half-written tree leaves a second engine behind, and relaunches on a crash up to five times a minute. `bin/omarchy-restart-shell` refuses while the lock screen is live, stops the shell and relaunches it through Hyprland so it keeps the session environment.

**VGS.** `vgsh run` takes a `flock`, writes its pid and execs `qs -p shell`; `shell.qml` draws and accepts state changes only when `VGSH_RUNNER_PID` is its own pid ([runtime.md](../architecture/runtime.md), invariant 1 in [overview.md](../architecture/overview.md)). Each plugin gets one IPC target whose lifetime it owns (`shell/Core/IpcRegistry.qml`). There is no stop or restart command, and `vgsh run` leaves Quickshell's file watcher on while the shell runs from the git checkout.

Quickshell 0.3.1 carries the session lock across a reload: `WlSessionLock::onReload` adopts the old lock manager, then `realizeLockTarget` calls `unlock()` when the new instance's `locked` is false (`src/wayland/session_lock.cpp`). VGS's `SessionLock.lockRequested` starts `false` in every new engine, and `shell/Hosts/LockHost.qml` binds `locked` to it. A file-watcher reload while the session is locked therefore unlocks it. No shipped plugin locks today, but the `lock` capability is open to any plugin.

**Verdict: keep the runner, lock, guard and CLI shape; adopt the watcher setting (finding 1) and a restart command (finding 2).** The lock and guard are stronger than `quickshell -n`, and a single `vgsh` file suits about 20 commands where Omarchy's router pays off at 470. Set `QS_DISABLE_FILE_WATCHER=1` and `QS_NO_RELOAD_POPUP=1` in `vgsh run`: the watcher reloads the whole shell on any `git pull` or branch switch in the checkout, and a reload while locked unlocks the session. Plugin changes already reload through the rescan. Add `vgsh restart`: refuse while the lock is held, stop the recorded pid, and start `vgsh run` again through `hyprctl dispatch exec` so it keeps the session environment. Leave Omarchy's crash relaunch loop out until a crash that needs it is seen. Quickshell's crash handler relaunches with `execve` in the crashed process (`src/crash/handler.cpp`), which should keep the pid the guard checks; no row tests it.

## Hyprland integration

**Omarchy.** Plugins read `Quickshell.Hyprland` directly and send commands as `hyprctl dispatch` shell strings from each plugin, with no reply check (`shell/plugins/bar/widgets/Workspaces.qml`). A static list, `default/omarchy/shortcuts`, is read twice: the shell makes a `GlobalShortcut` per entry and `default/hypr/helpers.lua` binds each. Omarchy ships its Hyprland configuration: layer rules in `default/hypr/apps/omarchy-shell.lua`, autostart in `default/hypr/autostart.lua`, and Lua only.

**VGS.** `shell/Core/Compositor.qml` (81 lines) is the one dispatch path: a queue of at most 32, one `hyprctl dispatch` at a time, and any reply other than `ok` is a failure. `shell/Core/Dispatch.js` checks every argument before it builds a request. `shell/Core/ShortcutRegistry.qml` makes one `GlobalShortcut` per plugin registration, named `<plugin id>:<name>`, released with the instance. VGS ships no Hyprland configuration; the plugin READMEs say what to bind.

**Verdict: keep the dispatch path and the shortcut model.** One checked, queued path is safer than unchecked strings in every plugin, and plugin-owned shortcut names need no shared list. The missing shipped configuration is VGS-489 (below).

## Install and update

**Omarchy.** A distribution: `install/` (86 files), package lists, `bin/omarchy-update` (pacman, then `bin/omarchy-migrate`, then a shell restart), 133 timestamped migrations run once per user with marker files, channels and a `version` file.

**VGS.** A git checkout: [README](../../README.md) states there is no install command and `bin/vgsh run` starts the shell. There is no migration runner. Plugins and themes have their own `add`, `update` and `remove`.

**Verdict: keep, and defer migrations.** The merged configuration removes the reason for most of Omarchy's migrations, and a checkout needs no package pipeline or channels. When the first release renames a plugin id, a marker-per-file runner like `bin/omarchy-migrate` (102 lines) is the right shape. A written list of runtime dependencies is under § Gaps.

## Design system and UI kit

**Omarchy.** `shell/Ui` is 35 files and 4,449 lines on `QtQuick.Controls`, including application parts such as `MultiSelect` and `KeyboardPanel`. Tokens are `Style.qml`, `Color.qml` and border geometry, about 1,400 lines, read from `colors.toml` and a per-theme `shell.toml` rendered from a 237-line template; a bad value falls back to its default key by key. Fonts come from fontconfig and icons are Nerd Font glyphs.

**VGS.** `shell/Ui` is 32 files and about 1,700 lines extending `QtQuick.Templates`, tested under `qmltestrunner` ([D017](../decisions/D017-templates-and-path-icons.md)). Tokens are one judged table of about 410 leaves; one bad token refuses the whole document ([D015](../decisions/D015-tokens-are-a-judged-table.md)). Two variable fonts ship ([D016](../decisions/D016-bundled-variable-font.md)) and icons are Lucide path data.

**Verdict: keep.** The kit is about 40 per cent of Omarchy's size for a comparable set, and it is tested. Seven palette colours still restyle every surface, so the larger token table costs a theme author nothing.

## Validation

**Omarchy.** `test/` runs node tests of JS models and CLI tests, 2 `qmltestrunner` files, and 17 runtime tests that start a second Quickshell on the user's live compositor and skip without one (`test/shell.d/runtime-smoke-test.sh`). Acceptance runs in a disposable VM from a separate repository.

**VGS.** `scripts/validate` selects checks from the diff. `scripts/qml-smoke.sh` runs 21 rows in a nested Hyprland sandbox; `scripts/qml-unit.sh` runs 15 offscreen QML test files; 38 `scripts/test-*` suites cover the CLI and judges ([D008](../decisions/D008-validation-row-per-change.md)).

**Verdict: keep.** The sandbox checks geometry, reserved space, layer lifecycle and the instance guard without the live seat, which is what Omarchy's runtime tests use and VGS forbids.

## Session lock

**Omarchy.** `shell/plugins/lock` (978 lines) owns its `WlSessionLock` and survives hot reload through `keepLoaded`. It authenticates through two PAM services, password and fingerprint, that `bin/omarchy-apply-lock` installs under `/etc/pam.d`.

**VGS.** The core owns the one `WlSessionLock` (`shell/Hosts/LockHost.qml`) and lends it through the `lock` capability (`shell/Core/SessionLock.qml`); a plugin hands over content only, and unloading it keeps the session locked. No lock plugin ships; the launcher's Lock entry runs `hyprlock`.

**Verdict: keep the core-owned lock.** A plugin cannot drop the lock by design, which removes Omarchy's `keepLoaded` special case. Finding 1 must land before any lock plugin, or a reload unlocks the session. A lock plugin with a password PAM service is under § Gaps.

## In-flight reworks

- **VGS-489, Hyprland Lua layer.** Agree. It delivers what Omarchy ships as `default/hypr/apps/omarchy-shell.lua` and its binds, as one managed include. One addition to consider: the shell's own autostart line, which Omarchy ships in `default/hypr/autostart.lua` and VGS documents nowhere. The classic-syntax half of `Dispatch.js` becomes dead weight if Lua is the only dialect VGS supports.
- **VGS-490, theme follows package.** Agree. It closes the one gap D025 leaves. Omarchy stages a copy of the package on every apply, so a shipped theme's fix reaches a user only when a migration re-applies it (`migrations/1787481315.sh` runs `omarchy-theme-refresh`); following the package automatically is simpler.
- **VGS-491, Chromium policy writer.** Landed as `62fc36fc` with [D029](../decisions/D029-chromium-policy-writer.md) superseding D027; agree, it follows Omarchy's narrow root-owned writer.
- **VGS-492, agent CLI targets.** Agree. Writing the theme file atomically into the CLI's own watched directory and setting its theme key is exactly Omarchy's `bin/omarchy-theme-set-claude` and `-pi`.
- **VGS-493, wallpaper in themes.** Landed as `513cc411`; agree that one plugin should own themes and wallpapers. Two points it leaves open, listed under § Gaps: VGS accepts only PNG and JPEG (`bin/lib/theme-backgrounds.js`), while most wallpapers a user brings are WebP, which Qt reads through `qt6-imageformats`; and a user directory of extra backgrounds per theme, as Omarchy's `~/.config/omarchy/backgrounds/<theme>/`, fits its Previous and Next controls. Finding 11 builds on it.
- **VGS-494, sandbox screenshots.** Landed as `ab0b7319` and `547e9bcf`; agree. It is VGS's version of Omarchy's VM acceptance screenshots, without the VM.

## Gaps

Omarchy has these; VGS has not built them. Each is a scope choice, not a defect, and none is proposed here.

- Bar position (bottom, left, right), transparency, drag reorder, custom `command` and `qml` modules, and a placement CLI (`omarchy bar put`, `move`, `set`).
- Bar widgets: tray, media, audio, network, Bluetooth, power and battery, keyboard layout, weather, DND and other indicators.
- Shell services: idle and screensaver, OSD, battery, night light, clipboard history, emoji picker, reminders, and a polkit agent plugin (the `polkit` capability exists with no holder).
- A lock plugin with a password PAM service; the launcher calls `hyprlock` instead.
- A curated launcher hide list (`default/omarchy/launcher.hides`), launch feedback and uninstall from the launcher.
- A user overlay directory of backgrounds, WebP and video wallpapers, and a lock screen that draws the wallpaper.
- A user `theme-set` hook, live OSC recolour of open foot and tmux panes, keyboard RGB and boot theming, 20 more themes, and an importer from `colors.toml`.
- A git URL transport allowlist (`bin/omarchy-git-url-check`); VGS relies on git's default protocol policy, which already refuses `ext::`.
- `plugin update` with no id, a crash-relaunch supervisor, journal logging, a fast IPC socket path and an IPC timeout.
- A written list of runtime dependencies.

## Risks and unknowns

- The session-lock finding comes from reading Quickshell 0.3.1's source and VGS's QML; no sandbox row reproduced it. The fix, one environment variable, does not depend on reproducing it.
- The wallpaper softness follows from `ShellScreen.width` being logical pixels; no screenshot at scale 2 confirms it. VGS-494's sandbox screenshots can supply one.
- The reload-hook lock time and the cost of `Lucide.js` (330 KB loaded whole) were not measured.
- Line counts are `wc -l` at the commits above and drift with both trees.

## Revisit conditions

- Omarchy ships its announced `omarchy.theme-switcher` shell plugin (`shell/plugins/README.md` § Coming soon), or moves its theme pipeline into the shell.
- VGS ships a lock plugin, a release that renames a plugin id, or a second consumer of the application list.

## Research metadata

- Sources: the two repositories and the Quickshell source at the commits above. No web source was used.
- Method: each area was read in both trees; every claim a verdict rests on was checked against the file it names.
- Proposals: 13, posted as `Proposal:` comments on VGS-495 after this report lands.
