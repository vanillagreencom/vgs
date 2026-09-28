# Theme targets

Covers: themes/targets/**, bin/lib/theme-render.js, scripts/test-theme-render.js, scripts/test-vgsh-targets.sh, scripts/test-vgsh-hyprland.sh

A target is one application's colour files: the directory `themes/targets/<target>/`, holding `target.json` and its templates. The renderer, `bin/lib/theme-render.js`, is pure: [themes.md § Boundaries](themes.md#boundaries). [theme-apply.md § Apply](theme-apply.md#apply) says when a target renders and where its files land.

## Targets

A target name is lower-case letters, digits and `-`, with no dot. `targets` under a themes directory holds targets and is never read as a package.

`acceptTarget` judges `target.json`. Every key but `wiring.section`, `wiring.profiles`, `wiring.vaults` and `reload.always` is required and any other key is refused with `reason=target-schema`. `wiring` takes one of two forms, told apart by `links`, or is `null`, and `wiringForm` names which, `include`, `entry` or `none`:

| Key | Holds |
|---|---|
| `app` | The application's name, one line. |
| `encoder` | The encoder every colour placeholder of the target is written with: [§ Templates](#templates). |
| `files` | One or more `{ template, destination }`, with an optional `curatedKeys`: [§ Templates](#templates). `template` is a file name in the target directory other than `target.json`. `destination` is the file name the render takes under the state directory's `theme/`: `<target>.<ext>`, unique in the target, so no two targets write one file. |
| `detect` | Command names; a target whose command is not an executable file in an absolute directory of `PATH` is skipped. An empty list is always detected. Detection never runs the command. |
| `wiring` | The include form, `{ file, line, create }`. `file` is the application's configuration file, relative to `${XDG_CONFIG_HOME:-~/.config}`, each segment a plain directory name. `line` is the one include line kept in that file; its only placeholder is `@{state}`, the state directory's `theme/` path, which it must hold. `create` is `true` when an absent `file` is created holding the line, `false` when the target is then skipped with reason `wiring-file-absent`. An optional `section`, one bare name of letters, digits, `_` and `-`, is the INI section or TOML table the line belongs in: [theme-wiring.md § Wiring text](theme-wiring.md#wiring-text). An optional `profiles` is one or more Mozilla `profiles.ini` paths relative to the home directory, each segment a name that may start with a dot, and makes `file` relative to each profile directory the first that exists lists: [theme-wiring.md § Profile wiring](theme-wiring.md#profile-wiring). The entry form, `{ base, dir, owned, links }`, edits no configuration file: [theme-wiring.md § Entry wiring](theme-wiring.md#entry-wiring). `null` keeps nothing outside the state directory, for a target whose hook asserts the setting its application reads the files through; apply adds and removes nothing for it. |
| `reload` | `null`, or `{ command, timeoutMs }`: the argv that makes a running application re-read its files, and its bound in whole milliseconds. `command[0]` is looked up on `PATH`. An argument's only placeholder is `@{state}`, the state directory's `theme/` path, which `reloadCommand` writes; `@@{` is a literal `@{`. Apply runs it after the theme file when the target's bytes changed or its reload is pending. An optional `always: true` also runs it on every apply that lands the target, unchanged bytes included, for a hook that asserts a setting no file carries: [theme-apply.md § Reload](theme-apply.md#reload). |

`bin/vgsh-theme-judge packages themes`, the offline row, renders every target under `themes/targets/` against the shipped `vgs` package and prints one line per target, `ok       targets/<target>` or `refused  <dir>: target=<target> reason=<key> <detail>`. A template or `target.json` that cannot be read, or targets without an accepted `vgs` package holding terminal slots, exit 2.

The shipped targets:

| Target | Encoder | Detect | Wiring | Reload |
|---|---|---|---|---|
| `alacritty` | `hex6` | `alacritty` | `import = ["@{state}/alacritty.toml"]` in the `general` table of `alacritty/alacritty.toml`, created when absent. | `touch -c` of `alacritty.toml`. |
| `foot` | `hex6` | `foot` | `include=@{state}/foot.ini` in `foot/foot.ini`, created when absent. Both `[colors-dark]` and `[colors-light]` hold the theme. | None. |
| `ghostty` | `hex6` | `ghostty` | `config-file = ?@{state}/ghostty.conf` in `ghostty/config.ghostty`, created when absent. | `SIGUSR2` to the user's `ghostty` processes. |
| `hyprland` | `hyprland` | `hyprctl` | `source = @{state}/hyprland.conf` first in `hypr/hyprland.conf`, never created: Hyprland v0.56.2 reads `hyprland.lua` when it exists and falls back to `hyprland.conf` only without it (its log line `[cfg] Lua config not found, using legacy config`), so a session configured in Lua alone is skipped with `wiring-file-absent`. | `hyprctl reload` within 5000 ms. It names no instance: hyprctl takes the session's `HYPRLAND_INSTANCE_SIGNATURE`. |
| `kitty` | `hex6` | `kitty` | `include @{state}/kitty.conf` in `kitty/kitty.conf`, created when absent. | `SIGUSR1` to the user's `kitty` processes. |
| `wezterm` | `hex6` | `wezterm` | `pcall(dofile, "@{state}/wezterm.lua")` first in `wezterm/wezterm.lua`, never created. | `touch -c` of `wezterm.lua`. |

The Hyprland file defines `$vgs_` colour variables a user's own settings can name, and colours the window, group and group bar borders with them; the file's own settings after the source line override it. Each terminal draws its foreground, background, selection, cursor and sixteen slots from the theme; kitty also its URL colour.

- **Precedence.** Alacritty reads an import before the importing file, and kitty and foot read the include line where it stands, so the file's own settings override the theme. Ghostty reads a `config-file` after the whole configuration, so the theme overrides the file's own colours; its `?` makes a missing theme file no error.
- **WezTerm.** It has no include directive. Its theme file wraps `wezterm.config_builder`, when that exists, so a config it builds starts on the `vgs` colour scheme, and a `color_scheme` or `colors` the file sets afterwards overrides it. A configuration not built by `config_builder` takes no theme, and neither does a `~/.wezterm.lua`, since the wiring file is relative to the configuration home. `pcall` keeps a missing theme file from failing the whole configuration.
- **Signals.** A `pkill -x -u` of the user's processes by exact name that matches none succeeds, so an application that is not running is not left pending. Ghostty reloads on `SIGUSR2` from 1.2.0; an older Ghostty is ended by it.
- **Touch.** Alacritty watches the directory of each file it imports, which the swap replaces, and WezTerm watches no file its configuration reads with `dofile`. The hook changes only the time of the configuration file each one watches, so it reads its configuration and the theme again; both reload so only with their automatic reload on, the default.

The editor targets, their table and their one-time steps are in [theme-editors.md](theme-editors.md).

The GTK, Qt, KDE colour scheme and icon theme targets: [theme-toolkits.md](theme-toolkits.md).

The chat and tool targets: [theme-tool-targets.md](theme-tool-targets.md).

The browser targets, Zen and pywalfox, and why Chromium is none: [theme-browsers.md](theme-browsers.md).

## Templates

`renderTarget` renders every file of an accepted target from the package's resolved token values, the terminal slots and the package's curated files.

- **Placeholders.** `@{<path>}` is a token of the table and `@{terminal.color<N>}` a terminal slot, `color0` to `color15`. `@@{` is a literal `@{`. Every other character passes through, so `#{pane_id}` and `${HOME}` render whole.
- **Refusal.** A placeholder that names no token and no slot, a group included, refuses the target with `reason=placeholder template=<file> placeholder="<name>"`; a `@{` with no `}` after it refuses with `unterminated=<offset>`. The target renders no file.
- **Values.** A colour token and a slot are written through the target's encoder. Any other token is written as its resolved value: `@{space.sm}` is `6`, `@{scheme.mode}` is `dark` or `light`.
- **Cases.** A `choice` token's path may be followed by cases, each `|<option>=<text>`, the option ending at the first `=`: the placeholder is written as the text of the resolved option, so `@{scheme.mode|dark=vs-dark|light=vs}` is `vs` under a light package. The cases name every option of the token once, each with text; any other set, cases on another token or on a slot refuse the target with `reason=placeholder`.
- **Curated files.** A package's `targets/<destination>` is taken byte for byte in place of the rendered file of that destination. The template is rendered all the same, so a curated file never hides a bad placeholder. A `files` entry with `curatedKeys`, one or more top-level JSON keys, takes a curated file only when it is a JSON object holding one of them; any other file at that name, one that is not plain JSON included, leaves the render in place.
- **Terminal slots.** `terminalSource` takes the package's own `terminal.json`, else the shipped `vgs` package's. `apply` writes the same package's `terminal.json` into the state directory.

Encoders, each shown for `#ff5a3659`:

| Encoder | Writes | Example |
|---|---|---|
| `hex6` | `rrggbb`, alpha dropped | `ff5a36` |
| `hex8` | `rrggbbaa` | `ff5a3659` |
| `rgba` | `rgba(r, g, b, a)`, channels 0 to 255, alpha 0 to 1 to three decimals | `rgba(255, 90, 54, 0.349)` |
| `hyprland` | `rgba(rrggbbaa)` | `rgba(ff5a3659)` |

No encoder writes `#`: a template writes it where its application wants one, as `#@{palette.accent}`.

## Invariants

1. Each encoder's output, a choice token's value and its cases, every case rule's refusal, the `@@{` escape, the pass-through of `#{pane_id}`, the refusal of a placeholder naming no token or slot, every `target.json` rule, the curated precedence and its `curatedKeys` judgment, the terminal fallback, the wiring line's substitution and the wiring text's whole-line match, first-line placement, placement after the first header of its section or with the header at the end, and creation, and the removal's whole-line match of every copy hold. Enforced by `scripts/test-theme-render.js`, whose controls remove one rule each from a copy of the renderer, and, for the apply's placement in a section, by `scripts/test-vgsh-targets.sh`, with a judge copy that drops the section as its control. The entry form's keys, bases, directory segments, owned flag, link names and destinations, its form test and the links' targets hold under the same suite's controls, and so do the `profiles` key's admission, list and paths and every `profileDirs` rule: profile sections only, trimmed lines, a value holding `=`, the `IsRelative` flag and the relative and absolute paths, a null wiring's form, the reload's optional `always`, its argument's `@{state}` and the refusal of any other placeholder. A null-wired target lands with nothing written outside the state directory, under `scripts/test-vgsh-targets.sh` with a judge copy that plans it as unwired as its control.
2. Every placeholder of every target under `themes/targets/` names a token or a slot, and `targets/` is not listed as a package. Enforced by `bin/vgsh-theme-judge packages themes` and `scripts/test-vgsh-theme-judge.js`, and for list and apply by `scripts/test-vgsh.sh`.
3. A wiring that would give a TOML key twice fails its target and leaves the file byte for byte. Enforced by `scripts/test-theme-render.js` and, through the apply, `scripts/test-vgsh-targets.sh`, with a judge copy that takes the refusal for a wired file as its control.
4. Each shipped terminal target lands its file with its encoder, keeps its include line in its application's configuration file, in `general` for Alacritty, creates none for WezTerm, signals the user's kitty and Ghostty by exact name, a run matching no process succeeding, and touches the file Alacritty and WezTerm watch, only when its bytes change or its reload is pending. Enforced by `scripts/test-vgsh-targets.sh` under a PATH of stub detect and signal commands.
5. The `hyprland` target writes its colours with the `hyprland` encoder, lands nothing and creates no file when `hyprland.conf` is absent, keeps its source line first in one that exists, and runs `hyprctl reload`, with no `-i` and the session's signature, on changed bytes and on a pending reload only. Enforced by `scripts/test-vgsh-hyprland.sh` under a PATH holding a stub `hyprctl`, with `target.json` copies that create the file, drop the hook and write `hex8` as its controls. The nested smoke's Hyprland block in `scripts/smoke/rows/themes.sh` copies the target alone into the sandbox copy, which ships none, and runs the real hook on the nested instance and parses the wired file with `Hyprland --verify-config`; the nested compositor reads `hyprland.lua`, so a live session's borders restyling is checked by hand.
6. The profiles wiring's apply rules: [theme-wiring.md § Invariants](theme-wiring.md#invariants).
