# Theme targets

Covers: themes/targets/**, bin/lib/theme-render.js, scripts/test-theme-render.js

A target is one application's colour files: the directory `themes/targets/<target>/`, holding `target.json` and its templates. The renderer, `bin/lib/theme-render.js`, is pure: [themes.md § Boundaries](themes.md#boundaries). [themes.md § Apply](themes.md#apply) says when a target renders and where its files land.

## Targets

A target name is lower-case letters, digits and `-`, with no dot. `targets` under a themes directory holds targets and is never read as a package.

`acceptTarget` judges `target.json`. Every key is required and any other key is refused with `reason=target-schema`:

| Key | Holds |
|---|---|
| `app` | The application's name, one line. |
| `encoder` | The encoder every colour placeholder of the target is written with: [§ Templates](#templates). |
| `files` | One or more `{ template, destination }`. `template` is a file name in the target directory other than `target.json`. `destination` is the file name the render takes under the state directory's `theme/`: `<target>.<ext>`, unique in the target, so no two targets write one file. |
| `detect` | Command names; a target whose command is not an executable file in an absolute directory of `PATH` is skipped. An empty list is always detected. Detection never runs the command. |
| `wiring` | `{ file, line, create }`. `file` is the application's configuration file, relative to `${XDG_CONFIG_HOME:-~/.config}`, each segment a plain directory name. `line` is the one include line kept in that file; its only placeholder is `@{state}`, the state directory's `theme/` path, which it must hold. `create` is `true` when an absent `file` is created holding the line, `false` when the target is then skipped with reason `wiring-file-absent`. |
| `reload` | `null`, or `{ command, timeoutMs }`: the argv that makes a running application re-read its files, and its bound in whole milliseconds. |

`bin/vgsh-theme-judge packages themes`, the offline row, renders every target under `themes/targets/` against the shipped `vgs` package and prints one line per target, `ok       targets/<target>` or `refused  <dir>: target=<target> reason=<key> <detail>`. A template or `target.json` that cannot be read, or targets without an accepted `vgs` package holding terminal slots, exit 2.

The shipped targets:

| Target | Encoder | Detect | Wiring |
|---|---|---|---|
| `foot` | `hex6` | `foot` | `include=@{state}/foot.ini` in `foot/foot.ini`, created when absent. Both `[colors-dark]` and `[colors-light]` hold the theme. |

## Templates

`renderTarget` renders every file of an accepted target from the package's resolved token values, the terminal slots and the package's curated files.

- **Placeholders.** `@{<path>}` is a token of the table and `@{terminal.color<N>}` a terminal slot, `color0` to `color15`. `@@{` is a literal `@{`. Every other character passes through, so `#{pane_id}` and `${HOME}` render whole.
- **Refusal.** A placeholder that names no token and no slot, a group included, refuses the target with `reason=placeholder template=<file> placeholder="<name>"`; a `@{` with no `}` after it refuses with `unterminated=<offset>`. The target renders no file.
- **Values.** A colour token and a slot are written through the target's encoder. Any other token is written as its resolved value: `@{space.sm}` is `6`.
- **Curated files.** A package's `targets/<destination>` is taken byte for byte in place of the rendered file of that destination. The template is rendered all the same, so a curated file never hides a bad placeholder.
- **Terminal slots.** `terminalSource` takes the package's own `terminal.json`, else the shipped `vgs` package's. `apply` writes the same package's `terminal.json` into the state directory.

Encoders, each shown for `#ff5a3659`:

| Encoder | Writes | Example |
|---|---|---|
| `hex6` | `rrggbb`, alpha dropped | `ff5a36` |
| `hex8` | `rrggbbaa` | `ff5a3659` |
| `rgba` | `rgba(r, g, b, a)`, channels 0 to 255, alpha 0 to 1 to three decimals | `rgba(255, 90, 54, 0.349)` |
| `hyprland` | `rgba(rrggbbaa)` | `rgba(ff5a3659)` |

No encoder writes `#`: a template writes it where its application wants one, as `#@{palette.accent}`.

## Wiring text

`wiringLine` writes a target's `line` with `@{state}` replaced. `wiredText` decides the file's new text. A file that holds the line as one whole line is left alone; the line inside a comment or a longer line does not count. An absent file becomes the line alone. Otherwise the line goes first, ahead of every section: an INI file such as `foot.ini` reads it in its main section, and the file's own settings after it override the theme. The rest of the text is kept.

## Invariants

1. Each encoder's output, the `@@{` escape, the pass-through of `#{pane_id}`, the refusal of a placeholder naming no token or slot, every `target.json` rule, the curated precedence, the terminal fallback, the wiring line's substitution and the wiring text's whole-line match, first-line placement and creation hold. Enforced by `scripts/test-theme-render.js`, whose controls remove one rule each from a copy of the renderer.
2. Every placeholder of every target under `themes/targets/` names a token or a slot, and `targets/` is not listed as a package. Enforced by `bin/vgsh-theme-judge packages themes` and `scripts/test-vgsh-theme-judge.js`, and for list and apply by `scripts/test-vgsh.sh`.
