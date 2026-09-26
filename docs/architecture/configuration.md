# Configuration

Covers: shell/Core/Config.qml, shell/Commons/Color.qml, shell/Commons/Paths.qml, config/shell.json

The shell's configuration files: two layers of `shell.json` merged by entry id, and the theme file. `shell/Core/Config.qml` reads the first two, `shell/Commons/Color.qml` the third, and `shell/Commons/Paths.qml` derives the user directory once for both.

## Layers

`config/shell.json` is the shipped layer and `~/.config/vgs/shell.json` (under `XDG_CONFIG_HOME` when set) the user layer, [D006](../decisions/D006-two-configuration-layers.md). `PluginLogic.effectiveConfig` merges them: a user key replaces the shipped key whole, except `plugins`, merged by id with the user entry winning, and `disabledPlugins`, which is the user list when present. `scripts/test-plugin-logic.js` pins each merge rule and the seeding of the user `bar` key.

## shell.json keys

Both layers share one shape, judged by `PluginLogic.configError` after every parse. A file that fails the judge is in the `malformed` state: the last good value stands, the log names the defect, and every write is refused until the file passes again. A key outside this table is carried untouched.

| Key | Shape |
|---|---|
| `version` | `1` when present. |
| `bar.id` | A string: the active bar's plugin id. |
| `bar.layout.left[]`, `bar.layout.center[]`, `bar.layout.right[]` | Objects, each with a string `id` and the widget's settings beside it. |
| `plugins[]` | Objects, each with a string `id` and the plugin's settings beside it. |
| `disabledPlugins[]` | Strings: plugin ids. |

## States

- Each file is in one state: `pending`, `loaded`, `absent` (the user file), `unparseable`, `unreadable` or `malformed`. `listPlugins` reports both.
- The configuration is ready once the shipped file has loaded once and the user file has settled. Nothing is built before that, so a bar never draws from the user file alone.
- A file that fails after one load keeps its last good value, so the shell draws from what it has and the log names the cause.
- Every write is refused unless the user file is `loaded` or `absent`, so a file the shell could not read is never overwritten unread. A write the disk refuses restores the value in memory and refuses the next write once with the error; `ok` from a write means the save was queued.

## Theme

`~/.config/vgs/theme.json` holds the palette: `foreground`, `background`, `accent`, `urgent` and `muted`, each a colour string. `Color.qml` reads it the way `Config.qml` reads `shell.json`: an absent file is the expected case, and a file that does not parse or holds a non-string value is logged and leaves the last good palette. The bar's font is the `Style.font.family` token, not a theme value.

## Decisions

[D006](../decisions/D006-two-configuration-layers.md).
