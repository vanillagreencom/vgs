# Theme wiring

Covers: bin/lib/theme-render.js, bin/vgsh-theme-judge, scripts/test-theme-render.js, scripts/test-vgsh-entries.sh

How a landed target's files reach its application: the include line kept in a configuration file, the Mozilla profiles it is kept in, and the entry form's links. The target format is [theme-targets.md § Targets](theme-targets.md#targets); when apply wires and unwires is [theme-apply.md § Apply](theme-apply.md#apply).

## Wiring text

`wiringLine` writes a target's `line` with `@{state}` replaced. `wiredText` decides the file's new text. A file that holds the line as one whole line is left alone; the line inside a comment or a longer line does not count. The rest of the text is kept.

- **No section.** An absent file becomes the line alone. Otherwise the line goes first, ahead of every section: an INI file such as `foot.ini` reads it in its main section, and the file's own settings after it override the theme.
- **A section.** The line goes right after the first header of that section, `[<section>]` with whitespace around the name and a `#` comment after it allowed; `[[<section>]]` is no header of it. A file without one, an absent file included, takes the header and the line at its end, so a TOML file never declares the table twice, which a dotted key ahead of its `[<section>]` header would.
- **The key already assigned.** A section that already assigns the line's key, up to the next header of any kind, on one line holding a one-line array of basic or literal strings takes the line's own string instead, when the line assigns a one-line array of one string. The string goes first in the array with `, ` after it, and every other byte of that line stays, its comment included; an array that already holds it is left. Alacritty loads its imports in order, a later one replacing a field an earlier one set, and the importing file last ([alacritty(5) § GENERAL](https://alacritty.org/config-alacritty.html#general)), so an Alacritty configuration's own `general.import` files and settings override the theme.
- **Refused.** A wiring that would give TOML a key twice is refused with `reason=wiring-conflict section=<section> key=<key>` and the file is left: any other assignment of the key in the section, a multi-line array, a value that is no array of strings, a second assignment of the key or anything after the `]` but a comment, or, with no header, a line ahead of every header that assigns `<section>` or a `<section>.` key.

`unwiredText` undoes it for a disabled target: every whole line equal to the include line goes, with its line break, and so does every copy of the line's string from the array that took it, in the section under the first header, with the separator after it, or the one before it for the last of several. Every other byte stays, a header `wiredText` added included. An empty array that took the string is then the include line itself, which goes whole.

## Profile wiring

A Mozilla-family browser keeps its configuration in profile directories with random names, listed in a `profiles.ini`. An include target with `profiles` keeps its line in `file` under every one of them. Zen's is `~/.config/zen/profiles.ini` for a new install, and `~/.zen/profiles.ini` wherever `~/.zen` exists, which Zen keeps using: its [release notes](https://zen-browser.app/release-notes/) ("compatibility with the old configuration directory (`~/.zen`) will be enabled if the directory exists"). A profile's `chrome/userChrome.css` is one such file: CSS reads an `@import` only ahead of every other rule, and the line goes first.

- **Which ini.** The paths are tried in order and the first that exists is read; the rest are ignored, as Zen reads one. Each is relative to the home directory, `XDG_CONFIG_HOME` not consulted.
- **Profiles.** `profileDirs` reads the ini: each `[Profile<N>]` section's `Path`, under the ini's own directory when its `IsRelative` is `1`, else absolute. Keys and values are trimmed. A section without a `Path`, one whose `IsRelative` is not `1` and whose `Path` does not start with `/`, and every other section, `[General]` and `[Install<hash>]` included, name no profile.
- **Wired and unwired.** A listed profile whose directory does not exist is not wired, so a stale entry never makes apply create a profile. Apply keeps the line in the file of every other listed profile and a disabled target's removal takes it from every one, each as [§ Wiring text](#wiring-text) edits one file. A profile no longer listed is not the target's, and a line left in it stays.
- **Skipped or failed.** No existing ini, or one listing no profile whose directory exists, skips the target with `wiring-file-absent`, and so does any listed profile's absent `file` when `create` is `false`. An ini that cannot be read fails the target with `unreadable`.

## Fallback files

An include target with `fallbacks` first tries `file` under the configuration home. When that file is absent, it tries each fallback path under the home directory and wires the first that exists. When none exists, the wiring file stays `file` under the configuration home, so `create: true` creates it there and `create: false` skips with `wiring-file-absent`.

`fallbacks` uses the same HOME-relative path shape as `profiles` and is refused together with `profiles`. The lookup treats only `ENOENT` as absent; a directory or another read failure fails the target with `unreadable`. A dangling symlink is absent for lookup, and the later file edit still refuses to create through one.

## Entry wiring

Helix, Zed and VS Code take their theme through this form; any target whose application finds its theme in a directory of its own may.

An application that reads no include line from its configuration finds its themes by name in a directory of its own, such as Helix's `~/.config/helix/themes/`. The entry form keeps links there instead: [D022](../decisions/D022-theme-apply-keeps-managed-links-in-application-directories.md). The user selects the theme once in the application.

| Key | Holds |
|---|---|
| `base` | `config` for `${XDG_CONFIG_HOME:-~/.config}`, `home` for the home directory, `cache` for `${XDG_CACHE_HOME:-~/.cache}`. |
| `dir` | The directory the links stand in, relative to `base`, each segment a directory name that may start with a dot: `.vscode/extensions/vgs-theme`. |
| `owned` | `true` when `dir` itself belongs to the target, such as an extension directory; `false` when it is the application's own directory. |
| `links` | One or more `"<name>": "<destination>"`: a link's file name in `dir`, and the target file it names, one of the target's `destination`s. |
| `vaults` | Optional. An Obsidian vault registry relative to `base`, each segment a name that may start with a dot, such as `obsidian/obsidian.json`; `dir` is then relative to each vault it lists. |

`entryLinks` answers each link's `name` and `to`, its destination under the state directory's `theme/`. `wiringLine` refuses an entry target and `entryLinks` an include target.

- **Managed.** A link is the target's when it is a symlink whose target is exactly its `to`. Apply writes no other kind of entry, and nothing else points into the state directory's `theme/`, so a symlink to it proves the link is managed without a marker file. A managed link whose file is gone is still managed.
- **Occupied.** A `dir` that exists and is no directory, or a link path holding anything but its managed link, a file, a directory or a symlink to elsewhere, skips the target with reason `entry-occupied`. Nothing at that path is replaced.
- **Vaults.** `vaultDirs` reads the registry's `vaults.<id>.path`, each absolute one once, in its order. A vault whose first `dir` segment is no directory, one that is gone or was never opened, takes no links. An absent registry, or one listing no such vault, skips the target with `wiring-file-absent`; one that cannot be read, or that is no JSON object with an object `vaults`, fails it with `unreadable`, on apply and on disable. Apply keeps the links in every such vault, and a disabled target's removal takes them from every one.
- **Symlinked directories.** `dir` and its parents are followed where they stand, so a dotfile manager's link to a directory serves, and the link is created in the directory it names.

## Invariants

1. The `vaults` key's admission and path and every `vaultDirs` rule hold: a JSON object, a registry without `vaults`, an object `vaults`, an object vault, an absolute path and each path once. Enforced by `scripts/test-theme-render.js`, whose controls remove one rule each from a copy of the renderer. Through the apply, `scripts/test-vgsh-chat-tools.sh` holds the links in every opened vault: [theme-tool-targets.md § Invariants](theme-tool-targets.md#invariants).
2. A profiles target reads the first of its inis that exists, found under HOME alone, and wires and unwires the file of every profile it lists whose directory exists, a relative one under the ini's directory and an absolute one where it names, and never a file under the configuration home; no ini, no existing listed profile, or with `create` false an absent profile file, skips it; an ini that cannot be read fails it, on apply and on disable. Enforced by `scripts/test-vgsh-targets.sh` with a fixture target, with judge copies that ignore `profiles`, put a relative profile under HOME, wire only the first profile, try the last ini first, wire a profile whose directory is absent, land a target with no ini and skip only when every file is absent as its controls. The `profiles` key's admission, list and paths and every `profileDirs` rule hold under the controls of `scripts/test-theme-render.js`.
3. A fallback target wires the configuration-home file when it exists, else the first existing HOME-relative fallback, else skips or creates the configuration-home file by its `create` flag. Its hook receives that same file through `@{wiring}`. Enforced by `scripts/test-vgsh-targets.sh` on WezTerm, with judge copies that ignore fallbacks, try a fallback before `file`, try fallbacks in reverse order and pass the hook a file other than the wired one as controls. The `fallbacks` key's admission, list shape, path shape and exclusion with `profiles`, the `@{wiring}` placeholder gate and the reload predicate that names `@{wiring}` hold under `scripts/test-theme-render.js` controls.
