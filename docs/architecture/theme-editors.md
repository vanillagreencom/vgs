# Theme editors

Covers: themes/targets/neovim/**, themes/targets/emacs/**, themes/targets/helix/**, themes/targets/zed/**, themes/targets/vscode/**, scripts/test-vgsh-editors.sh, scripts/test-vgsh-editor-entries.sh

The editor targets, one per editor, beside the others of [theme-targets.md § Targets](theme-targets.md#targets):

| Target | Encoder | Detect | Wiring | Reload |
|---|---|---|---|---|
| `emacs` | `hex6` | `emacs` | `(load "@{state}/emacs.el" nil t)` in `emacs/vgs-theme.el`, created when absent. | `emacsclient -a true --eval "(when (custom-theme-enabled-p 'vgs) (load-theme 'vgs t))"`, 5000 ms. |
| `helix` | `hex6` | `helix` or `hx` | Link `vgs.toml` in `helix/themes`. | `sh -c "pkill -USR1 -x -u \"$(id -u)\" 'hx\|helix'; [ $? -le 1 ]"`, 5000 ms. |
| `neovim` | `hex6` | `nvim` | `do return dofile("@{state}/neovim.lua") end` in `nvim/lua/plugins/vgs-theme.lua`, never created. | None. |
| `vscode` | `hex8` | `code` | Links `package.json` and `vgs-color-theme.json` in `~/.vscode/extensions/vgs-theme`, owned. | None. |
| `zed` | `hex8` | `zeditor` or `zed` | Link `vgs.json` in `zed/themes`. | None. |

Each editor needs one step from the user, named below, before it draws the theme. After that, every apply keeps the theme in place.

## Neovim

`neovim.lua` is a [lazy.nvim plugin spec](https://lazy.folke.io/usage/structuring), the form Omarchy's packages ship as their curated `neovim.lua`. lazy.nvim imports every file of `lua/plugins/` when its setup lists `{ import = "plugins" }`, as the LazyVim starter does, and a Neovim without that import never reads the file. The user creates `vgs-theme.lua` holding `return {}`. The include line returns the rendered spec ahead of it, and removing the line for a disabled target leaves `return {}`, which lazy.nvim still accepts; an empty file is a spec error. The fallback adds no plugin: it returns `{}` and sets its highlight groups and `terminal_color_0` to `15` on `VimEnter`, after any colorscheme a plugin loads at startup. lazy.nvim reads specs only at startup, so the target has no reload and a running Neovim takes the theme at its next start.

## Emacs

`emacs.el` defines the custom theme `vgs`. `vgs-theme.el` is the theme file [`load-theme`](https://www.gnu.org/software/emacs/manual/html_node/emacs/Custom-Themes.html) finds in `custom-theme-directory`, which is `user-emacs-directory`, so it serves an Emacs using `~/.config/emacs/`; an Emacs using `~/.emacs.d/` adds `~/.config/emacs/` to `custom-theme-load-path`. The user enables the theme with `(load-theme 'vgs t)`. The line is not kept in `init.el`, because Emacs reads a `lexical-binding` cookie only on the file's first line, which the include line would take. `load-theme` on an enabled theme loads its file again, and the hook asks the running server to do it through [`emacsclient --eval`](https://www.gnu.org/software/emacs/manual/html_node/emacs/emacsclient-Options.html). With no server, `-a true` runs `true` in its place, so an Emacs that is not running is not left pending. The 5000 ms bound is not measured: no Emacs was installed where the target was written.

## Helix

- **Wiring.** The link is `~/.config/helix/themes/vgs.toml`. Helix finds a theme by its file name in its `themes` directory ([Helix themes](https://docs.helix-editor.com/themes.html)). The user sets `theme = "vgs"` in `config.toml` once. Helix takes no alpha, so the target writes `#rrggbb`.
- **Reload.** Helix reads its configuration and its theme from disk again on `:config-reload` and when it receives `SIGUSR1` ([Helix configuration](https://docs.helix-editor.com/configuration.html); `refresh_config` in `helix-term/src/application.rs` loads the configured theme again). The hook sends `USR1` to the user's own processes named `hx` or `helix`. `pkill` exits 1 when no process matches, and `[ $? -le 1 ]` counts that as success, so a Helix that is not running is not left pending. Any other status fails the reload. The 5000 ms bound is not measured: no Helix was installed where the target was written.
- **Detect.** Arch's `helix` package installs the command as `helix`, and an upstream build installs `hx`. The target's `detect` is `[["helix", "hx"]]`, so either one detects it ([theme-targets.md § Targets](theme-targets.md#targets)).

## Zed

- **Wiring.** The link is `~/.config/zed/themes/vgs.json`, the directory [Zed's theme docs](https://zed.dev/docs/themes) name for local themes. The file is a theme family in the [v0.2.0 schema](https://zed.dev/schema/themes/v0.2.0.json), and its colours are `#rrggbbaa`. The user selects `vgs` once in the theme selector.
- **Appearance.** The theme's `appearance` is the package's `scheme.mode`, `dark` or `light` ([themes.md § Package shape](themes.md#package-shape)), written by `@{scheme.mode}`. Zed fills every colour the template does not name from its default theme of that appearance.
- **Reload.** None. Zed loads user themes when it starts, and it watches the themes directory (`watch_themes` in `crates/zed/src/main.rs`). A running Zed therefore loads the link the first apply creates. A later apply changes the file the link names, not the entry in Zed's directory, so the watch never sees it, and Zed has no command or signal that reads a theme file again. A running Zed shows a later theme only after the user restarts it.
- **Detect.** Arch's `zed` package installs the command as `zeditor`, and the upstream installer installs `zed`. The target's `detect` is `[["zeditor", "zed"]]`, so either one detects it.

## VS Code

- **Wiring.** The target owns `~/.vscode/extensions/vgs-theme`. Its `package.json` names the extension `vgs.vgs-theme` 1.0.0, which contributes the colour theme `vgs` from `vgs-color-theme.json` ([Color Theme guide](https://code.visualstudio.com/api/extension-guides/color-theme), [`contributes.themes`](https://code.visualstudio.com/api/references/contribution-points#contributes.themes)). Its colours are `#rrggbbaa`. The colour theme's `type` is the package's `scheme.mode`, and its contribution's `uiTheme`, the base VS Code fills every colour the theme omits from, is `vs-dark` for `dark` and `vs` for `light`, written by `@{scheme.mode|dark=vs-dark|light=vs}` ([theme-targets.md § Templates](theme-targets.md#templates)). The apply installs nothing from the marketplace, runs no `code --install-extension`, and edits neither `settings.json` nor `extensions.json`.
- **Registration.** Since VS Code 1.74, `~/.vscode/extensions/extensions.json` lists the user's extensions. `extensionManagementService.ts` and `extensionsWatcher.ts` in `src/vs/platform/extensionManagement/node/` decide what happens to a folder that list does not name:
  - While VS Code runs, it adds a new folder in the extensions directory to the default profile as an extension from another source. The folder's name does not matter; `package.json` gives the extension its identity.
  - When VS Code starts, it deletes every extension folder no profile lists. An apply that wrote the folder while VS Code was closed has its folder deleted at the next start. The deletion removes the links, never the files in `theme/`, and the next apply writes the folder again.
- **One-time step.** Run `vgsh theme apply` while VS Code is running, then choose `vgs` with `Preferences: Color Theme`. `Developer: Install Extension from Location...` also registers the folder where it stands, but only while the folder exists and VS Code is running.
- **Curated file.** `vscode.json` takes `curatedKeys` `colors`, `tokenColors` and `semanticTokenColors` ([theme-targets.md § Templates](theme-targets.md#templates)). A package's colour theme is therefore taken, while Omarchy's `vscode.json` is not: it names a marketplace extension, so the target draws the token render in its place.
- **Reload.** None. VS Code reads an extension's colour theme when a window loads. A later apply changes the linked file, and VS Code shows it after `Developer: Reload Window`.
- **Detect.** `code` is Microsoft's VS Code. Code - OSS, the command Arch's `code` package installs, and VSCodium read `~/.vscode-oss/extensions` instead (`dataFolderName` in `product.json`). On those, the target writes a folder that nothing reads.

The entry form's rules: [theme-wiring.md § Entry wiring](theme-wiring.md#entry-wiring).

## Invariants

1. The `neovim` and `emacs` targets render their colours as `#rrggbb` from the package's tokens and slots, are skipped when their command is not on `PATH` or, for `neovim`, when the spec file is absent, keep their include line in the file their application reads, take a package's curated file byte for byte, and `emacs` runs its hook with its pinned argv. A disabled `neovim` leaves the user's spec file as it was. Enforced by `scripts/test-vgsh-editors.sh` under a PATH of stub commands, with target copies that write `hex8`, drop `-a true` and create the spec file as its controls.
2. The `helix`, `zed` and `vscode` targets are covered by `scripts/test-vgsh-editor-entries.sh` under a PATH of stub commands, `sh` included. The suite checks that each target:
   - renders its colours as `#rrggbb` into TOML Helix parses, or as `#rrggbbaa` into JSON Zed and VS Code parse;
   - is skipped when its command is not on `PATH`, and detected by `hx` alone for `helix` and `zed` alone for `zed`;
   - keeps its links in its editor's directory, VS Code's owned directory included;
   - takes a package's curated file byte for byte;
   - skips itself when a file of the user's stands at the link path, and keeps that file.

   It also checks that the shipped `vgs` package marks the Zed theme and the VS Code colour theme `dark` on the `vs-dark` base, and `light` marks them `light` on the `vs` base.
   `vscode` renders its own theme in place of a `vscode.json` naming an extension, and loses its owned directory when disabled. `helix` runs its hook with its pinned argv, and never on unchanged bytes. The controls are target copies that switch each encoder, detect `helix` and `zed` by their Arch names alone, drop `curatedKeys`, move `vscode` to the `config` base, fix Zed's appearance and VS Code's `type` at `dark`, map `light` to `vs-dark`, and drop the hook's tolerance of no Helix running, with a judge copy that requires every name of a list entry.
