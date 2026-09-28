# Chat and tool targets

Covers: themes/targets/vesktop/**, themes/targets/equibop/**, themes/targets/vencord/**, themes/targets/btop/**, themes/targets/fastfetch/**, themes/targets/tmux/**, themes/targets/oh-my-posh/**, themes/targets/obsidian/**, scripts/test-vgsh-chat-tools.sh

The shipped targets for chat clients and terminal tools. The target format, both wiring forms and the renderer are [theme-targets.md](theme-targets.md); when a target lands and when its hook runs is [theme-apply.md](theme-apply.md).

## Targets

Every target here uses the `hex6` encoder, and its templates write the `#`.

| Target | Detect | Wiring | Reload |
|---|---|---|---|
| `btop` | `btop` | Link `vgs.theme` in `btop/themes`. | `SIGUSR2` to the user's `btop` processes. |
| `equibop` | `equibop` | Link `vgs.css` in `equibop/themes`. | `touch -h -c` of the link. |
| `fastfetch` | `fastfetch` | Link `vgs.jsonc` in `fastfetch`. | None. |
| `obsidian` | `obsidian` | Links `theme.css` and `manifest.json` in `.obsidian/themes/vgs`, owned, in every vault `obsidian/obsidian.json` lists. | None. |
| `oh-my-posh` | `oh-my-posh` | Link `vgs.omp.json` in `oh-my-posh`. | None. |
| `tmux` | `tmux` | `source-file -q '@{state}/tmux.conf'` first in `tmux/tmux.conf`, never created. | `tmux source-file -q` of the theme file when `tmux list-sessions` finds a server. |
| `vencord` | `discord` | Link `vgs.css` in `Vencord/themes`. | `touch -h -c` of the link. |
| `vesktop` | `vesktop` | Link `vgs.css` in `vesktop/themes`. | `touch -h -c` of the link. |

Every path is relative to `${XDG_CONFIG_HOME:-~/.config}`. A linked theme is selected once in its application: `vgs` in btop's colour themes, Vencord's themes list, and Obsidian's appearance settings of each vault; `fastfetch --config vgs`; `oh-my-posh init <shell> --config ~/.config/oh-my-posh/vgs.omp.json`. Apply never edits `btop.conf`, fastfetch's `config.jsonc`, Vencord's settings or a vault's `appearance.json`.

- **Discord clients.** Vesktop, Equibop and Vencord read `.css` files from `<data>/themes/`, where `<data>` is Vesktop's and Equibop's own configuration directory, and for Vencord the `Vencord` directory beside Discord's own `discord`. `equibop.css` and `vencord.css` are copies of `vesktop.css`, so the three render one file. It imports refact0r's midnight theme from `refact0r.github.io` and sets the colour variables midnight draws Discord from. Each client watches its themes directory, and the hook changes only the link's own time, which that watch sees once the swap has replaced `theme/`.
- **btop.** btop reads its configuration and themes again on `SIGUSR2` from 1.3.1; an older btop is ended by it. A `pkill -x -u` that matches no process succeeds.
- **fastfetch.** fastfetch loads one configuration and has no include. The linked file is a whole configuration, found by `--config vgs` in its configuration directory, and needs fastfetch 2.42.0 for `#RRGGBB` colours.
- **tmux.** tmux loads `~/.tmux.conf` and then `$XDG_CONFIG_HOME/tmux/tmux.conf`, each when it exists. Created, the second file would hold the theme over a `~/.tmux.conf` user's own settings, and plugin managers such as TPM read their plugin list from it first, so an absent one skips the target with `wiring-file-absent`. The file's own settings after the line override the theme at start. The hook reaches the server of tmux's default socket, or the one `$TMUX` names, and sources the theme over the running options. With no server there is nothing to reload, and the hook succeeds. The style options take `#{...}` formats, tmux 3.2's, which the render leaves whole.
- **Oh My Posh.** The linked file is a whole prompt configuration whose segments draw from its `palette`, and a configuration of the user's may `extends` it. Oh My Posh caches its configuration, so a running shell takes a new theme once `oh-my-posh enable reload` is on or when a new shell starts.
- **Obsidian.** A theme is a directory of `theme.css` and `manifest.json` under a vault's `.obsidian/themes/`; Obsidian has no theme directory outside the vaults. The `vaults` key keeps the links in every vault the registry lists: [theme-wiring.md § Entry wiring](theme-wiring.md#entry-wiring). Obsidian reads the theme when a vault opens or the theme is selected.

## Invariants

1. Each target here lands its file with `hex6`, the three Discord targets one file between them; keeps its links in its application's directory, Obsidian's in every opened vault and none in a vault that is gone or never opened, and never edits a settings file beside them; keeps tmux's line first in an existing `tmux.conf` and creates none; touches each Discord link, signals btop by exact name and sources the theme into a running tmux server on changed bytes and on a pending reload only; and leaves `#{pane_id}` in the tmux file whole. An absent or empty registry skips Obsidian, one that is no vault list fails it, and disabled it loses its links and its owned directory in every vault. Enforced by `scripts/test-vgsh-chat-tools.sh` under a PATH of stub detect, signal and tmux commands, with a `target.json` copy that creates `tmux.conf` and judge copies that ignore `vaults`, link unopened vaults, keep or drop the links of the first vault only, land a target whose registry lists no vault and read an unparseable registry as empty as its controls.
