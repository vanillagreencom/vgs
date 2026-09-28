# Theme agent CLIs

Covers: themes/targets/claude/**, themes/targets/codex/**, themes/targets/gemini/**, themes/targets/hermes/**, themes/targets/omp/**, themes/targets/opencode/**, themes/targets/pi/**, bin/lib/theme-select.js, scripts/test-theme-select.js, scripts/test-vgsh-agents.sh

The shipped targets for coding-agent terminal CLIs, and the `select` key that sets a CLI's theme by name in its own settings file. The target format, both wiring forms and the renderer are [theme-targets.md](theme-targets.md); when a target lands and when its hook runs is [theme-apply.md](theme-apply.md). [D024](../decisions/D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md) records why apply edits these settings files.

## Targets

Every target here uses the `hex6` encoder, and its templates write the `#`. No template names a translucent token: `hex6` drops alpha, so a 14 % fill would draw as the whole colour. Fills take the opaque `color.surface*` and `color.border*` neutrals.

| Target | Detect | Wiring | Selection | Reload |
|---|---|---|---|---|
| `claude` | `claude` | Link `vgs.json` in `~/.claude/themes`. | `"theme": "custom:vgs"` in `~/.claude/settings.json`. | `touch -h -c` of the link, 5000 ms. |
| `codex` | `codex` | Link `vgs.tmTheme` in `~/.codex/themes`. | `theme = "vgs"` under `[tui]` in `~/.codex/config.toml`. | None. |
| `gemini` | `gemini` | None. | `ui.theme` set to the state file's path, `<state>/theme/gemini.json`, in `~/.gemini/settings.json`. | None. |
| `hermes` | `hermes` | Link `vgs.yaml` in `~/.hermes/skins`. | `display.skin: vgs` in `~/.hermes/config.yaml`. | None. |
| `omp` | `omp` | Link `vgs.json` in `~/.omp/agent/themes`. | `theme.dark: vgs` and `theme.light: vgs` in `~/.omp/agent/config.yml`. | None. |
| `opencode` | `opencode` | Link `vgs.json` in `${XDG_CONFIG_HOME:-~/.config}/opencode/themes`. | `"theme": "vgs"` in `${XDG_CONFIG_HOME:-~/.config}/opencode/tui.json`. | None. |
| `pi` | `pi` | Link `vgs.json` in `~/.pi/agent/themes`. | `"theme": "vgs"` in `~/.pi/agent/settings.json`. | None. |

A CLI whose home directory an environment variable moves, `CODEX_HOME`, `HERMES_HOME`, `PI_CODING_AGENT_DIR` or `CLAUDE_CONFIG_DIR`, is served only at its default directory. oh-my-pi also reads `PI_CODING_AGENT_DIR`.

## Selection

A target's optional `select` is `{ base, file, format, key, value }`:

| Key | Holds |
|---|---|
| `base` | `config`, `home` or `cache`, as an entry wiring's `base`: [theme-wiring.md § Entry wiring](theme-wiring.md#entry-wiring). |
| `file` | The settings file, relative to `base`, each segment a name that may start with a dot. |
| `format` | `json`, `toml` or `yaml`. |
| `key` | The key path, outermost first, each segment a bare name of letters, digits, `_` and `-`. `json` takes any depth; `toml` and `yaml` take `[key]` at the root or `[table, key]` in one table or top-level mapping. A list of two or more such paths sets each to the value; no path in it may equal another or lie on another's path. |
| `value` | One line with no control character. Its only placeholder is `@{state}`, the state directory's `theme/` path, which `selectValue` writes; `@@{` is a literal `@{`. |

`selectedText` in `bin/lib/theme-select.js` decides the file's new text: the text with every key holding the value, null when each already holds it, or a refusal. `selectKeys` in `bin/lib/theme-render.js` answers a target's keys as a list. Each key is set in the text the key before it left, under the rules below, and any key refused refuses the whole edit. Every byte the edit does not name is kept, and a line it adds takes the file's CRLF or LF line break.

- **Apply.** Step 1 skips a target whose settings file is absent, a dangling symlink included, with `selection-file-absent`, and one whose edit is refused with `selection-refused`, before anything lands, so its CLI keeps its last theme. Step 5 sets the key on every apply that lands the target, unchanged bytes included, so a theme changed by hand comes back. The file is resolved through symlinks and replaced by rename beside the resolved file with its mode kept, as an include line's file is: [theme-apply.md § Apply](theme-apply.md#apply). The staging copy beside it is created owner-only before any byte is written and takes the kept mode only once it is full, so a private settings file never has a readable copy. A file that already selects the value is not written.
- **Never created.** An absent settings file is never created: the CLI's own defaults stand until the user makes one.
- **Disabled.** A disabled target leaves the key as it stands. Apply does not know the user's previous theme, and the CLI falls back to its default when the theme file is gone.
- **Refusal.** `selection-refused` carries `format=<format> cause=<cause> key=<dotted key>`. `unparseable` is a JSON file `JSON.parse` refuses, comments and trailing commas included, or one whose root is no object. `not-a-table` is a table, mapping or intermediate object held in another form: a non-object, a quoted or array-of-tables TOML header, an inline table or dotted key at the TOML root, or a YAML map line with a value, anchor, tag or quotes after it, or a sequence under it. `not-a-string` is a key whose value is no single-line string or scalar, or whose name a header or dotted key makes a table. `duplicate-key` and `duplicate-table` are a key or table given twice. `tab` is a YAML line indented with a tab. `multi-document` is a YAML `---` or `...` after content.
- **JSON.** The whole file must parse. A present key's string token is replaced. A missing key is added as the first member of the deepest object on its path that exists, with the missing objects written on its line: `"ui": { "theme": ... }`. A multi-line object takes it on its own line at the indentation of its first member, a single-line object ahead of its first member on that line, and an empty object on a line two spaces deeper than its own.
- **TOML.** The edit reads each line on its own. `[table, key]` edits the lines under the one `[table]` header, as the wiring's section judgement reads a header, up to the next header of any kind. A single-line basic or literal string there has its token replaced, its line's key spelling, spacing and comment kept. A missing key goes right after the header, and a missing table is appended with the key. `[key]` edits the lines ahead of the first header and adds a missing key first in the file. The value is written as a basic string.
- **YAML.** Block style only. `[map, key]` edits the block of the one column-0 `map:` line, which runs to the next column-0 line that is not blank or a comment; the key's indent is that of the block's first line that is not blank or a comment, two spaces in an empty block. A plain or quoted single-line scalar has its token replaced, its comment kept. A missing key goes right after `map:`, and a missing map is appended with the key. `[key]` edits the column-0 lines and appends a missing key. The value is written plain when it is a word starting with a letter that YAML reads as no boolean or null, else double-quoted.

## Claude Code

Claude Code reads a custom theme from `~/.claude/themes/<slug>.json`, `{ name, base, overrides }`, and selects it with `"theme": "custom:<slug>"` in `~/.claude/settings.json`: [terminal-config § Create a custom theme](https://code.claude.com/docs/en/terminal-config#create-a-custom-theme). `base` is the scheme's mode, `dark` or `light`. `overrides` sets every documented token but the six diff fills, `diffAdded`, `diffRemoved`, their `Dimmed` and their `Word` forms: the token table holds no opaque tinted fill, so they take the base preset's. A project's `.claude/settings.json` or `.claude/settings.local.json` overrides the user file. Claude Code watches `~/.claude/themes/` and reloads a file added or changed there; if the directory did not exist when it started, it reads the theme at its next start. The swap replaces the file the link names, not the link, so the hook changes the link's own time for that watch to see; that the watch sees it has not been tested on a running session. Claude Code 2.1.283 was read.

## Codex

Codex reads a TextMate `.tmTheme` named by `[tui] theme` in `~/.codex/config.toml` from `~/.codex/themes/<name>.tmTheme`: `custom_theme_path` in [`codex-rs/tui/src/render/highlight.rs`](https://github.com/openai/codex/blob/rust-v0.157.0/codex-rs/tui/src/render/highlight.rs) and `Tui.theme` in the [configuration schema](https://developers.openai.com/codex/config-schema.json). The theme paints code and diffs on the terminal's own background, so it sets foregrounds alone. Codex reads it at start and has no watch, so a running Codex takes a new theme when it starts again. Codex 0.157.0 was read.

## Gemini CLI

Gemini CLI loads a theme file named by a `ui.theme` that ends in `.json` in `~/.gemini/settings.json`, and the file holds `name`, `type: "custom"` and its colour blocks: `bundle/docs/cli/themes.md` and `bundle/docs/reference/configuration.md` shipped in the `@google/gemini-cli` 0.61.0 package. The setting names the state file itself, so no link is kept. Gemini loads a theme file only when its resolved path is under the home directory, so an `XDG_STATE_HOME` outside it is not served. The theme sets no diff background, for the reason Claude's leaves its diff fills out. Gemini caches a file theme by its path for the life of the process, so a running session takes a new theme when it starts again.

## Hermes Agent

Hermes reads a skin from `~/.hermes/skins/<name>.yaml` and selects it with `display.skin` in `~/.hermes/config.yaml`: `load_skin` and `init_skin_from_config` in [`hermes_cli/skin_engine.py`](https://github.com/NousResearch/hermes-agent/blob/73a9dc598bd1a9058345fb20938759c7f9612b90/hermes_cli/skin_engine.py). Every colour is a double-quoted `#rrggbb`, the one form its skin commands accept. Hermes reads the skin at start; in a running session `/skin vgs` repaints the prompt, and the banner at the next start.

## oh-my-pi

oh-my-pi (`omp`) reads a theme from `~/.omp/agent/themes/<name>.json`, `{ name, colors, export }`, and keeps two selections in `~/.omp/agent/config.yml`, `theme.dark` and `theme.light`, picking one per session from the terminal's background: `docs/theme.md` and `docs/settings.md` of [oh-my-pi v18.3.1](https://github.com/can1357/oh-my-pi/tree/v18.3.1/docs). Both take `vgs`, so whichever slot the terminal selects draws the package applied last, whatever its mode. A flat `theme: <name>` is a legacy form oh-my-pi rewrites on load, so it is never written. The theme sets all 66 required `colors`, the optional `thinkingMax` and the 3 `export` colours of `packages/tui/src/theme/theme-schema.json`. A `config.yaml` is read only when no `config.yml` exists, and the target serves `config.yml` alone, so an install holding only `config.yaml` is skipped with `selection-file-absent`. oh-my-pi watches the active theme file and keeps the last theme it loaded when a reload fails; the swap replaces the file the link names rather than writing it, and whether a running session reads the new file has not been tested. A new start reads it. oh-my-pi 18.3.1 was read.

## opencode

opencode reads `themes/*.json` under `${XDG_CONFIG_HOME:-~/.config}/opencode`, `{ $schema, theme }`, and selects one with `"theme"` in `tui.json` beside it: `discoverThemes` in [`packages/tui/src/context/theme.tsx`](https://github.com/anomalyco/opencode/blob/03e67171ab2dc1e7f16e8cebfbc7f778f61b89f0/packages/tui/src/context/theme.tsx) and the `Theme` type in [`packages/tui/src/theme/index.ts`](https://github.com/anomalyco/opencode/blob/03e67171ab2dc1e7f16e8cebfbc7f778f61b89f0/packages/tui/src/theme/index.ts). The selection is never kept in `opencode.json`: opencode moves a theme key there into `tui.json` when it loads, and only when `tui.json` is absent, so an absent `tui.json` skips the target and leaves that move to opencode. One package is one mode, so each key holds one colour, no `{ dark, light }` pair. The diff backgrounds take the opaque surfaces, and added and removed lines differ by their text colour. opencode rescans its themes on `SIGUSR2`, but an opencode without that handler is ended by the signal, so none is sent and a running opencode takes a new theme when it starts again. opencode 1.18.32 was read.

## Pi

Pi reads a theme from `~/.pi/agent/themes/<name>.json` and selects it with `"theme"` in `~/.pi/agent/settings.json`: the themes guide and `theme/theme-schema.json` shipped in the Pi 0.87.1 package. The theme sets all 51 required and 5 optional `colors` and the 3 `export` colours the schema names. Pi watches the active theme file; the swap replaces the file the link names rather than writing it, and whether a running Pi reads the new file has not been tested. `/reload` or a new start reads it.

## Invariants

1. Every `selectedText` edit and refusal holds for each format: a key replaced, a key and its table, map or objects added, a file already holding the value left as it is, bytes outside the edit kept, a CRLF file's line break and every refusal cause; an absent file is never edited; and every `select` rule of `acceptTarget`, `selectValue`'s substitution and `selectKeys`'s list hold. A list of keys sets each key in the text the one before it left, and one refused key refuses it. Enforced by `scripts/test-theme-select.js`, whose controls remove one rule each from a copy of `theme-select.js` or `theme-render.js`.
2. Each target here lands its file with `hex6` in the form its CLI parses, keeps its link where the CLI reads it, Gemini none, and sets every key of its selection, both of oh-my-pi's slots included, with every other byte of the settings file kept, through a symlink and with its mode; an unchanged apply writes no settings file; a key changed by hand comes back on the next apply; an absent or dangling settings file skips its target and is never created; a file the edit refuses skips its target and is left byte for byte; a disabled target leaves its key; detection runs no CLI; and Claude's hook changes only its link's time. Enforced by `scripts/test-vgsh-agents.sh` under a PATH of stub detect commands, with judge copies that drop the plan's skip and never keep the selection as its controls.
3. No agent template names a translucent token: each rendered with `hex8` against the shipped package writes as many colours as its template has `#@{` placeholders, at least ten, each opaque. Enforced by `scripts/test-vgsh-agents.sh`, with a template copy naming `color.accentSubtle` as its control.
