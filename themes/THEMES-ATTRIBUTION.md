# Built-in theme provenance (Omarchy community imports)

VGS theme packages listed below were ported from community Omarchy theme repositories. Palettes, curated `neovim.lua` colorscheme specs, `btop.theme`, and bundled VS Code color-themes are taken from the source; per-file author credits inside those files are preserved verbatim. Wallpapers are the source backgrounds plus additional Wallhaven abstracts (see BACKGROUNDS-ATTRIBUTION.md).

| VGS theme | Source repository | License |
|-----------|-------------------|---------|
| `akane` | https://github.com/Grenish/omarchy-akane-theme | no LICENSE file |
| `amberbyte` | https://github.com/tahfizhabib/omarchy-amberbyte-theme | MIT |
| `arc-blueberry` | https://github.com/vale-c/omarchy-arc-blueberry | MIT |
| `arc-raiders` | https://github.com/rondilley/omarchy-arc_raiders-theme | GPL |
| `archwave` | https://github.com/davidguttman/archwave | no LICENSE file |
| `artzen` | https://github.com/tahfizhabib/omarchy-artzen-theme | no LICENSE file |
| `biscuit-de-mar` | https://github.com/OldJobobo/omarchy-biscuit-de-mar-dark-theme | no LICENSE file |
| `brutalism` | https://github.com/bjornramberg/omarchy-brutalism-theme | GPL |
| `coppernight` | https://github.com/hembramnishant50-glitch/omarchy-coppernight-theme | no LICENSE file |
| `cpunk` | https://github.com/stannorbvb-cmd/cpunk | no LICENSE file |
| `delorean` | https://github.com/jbnunn/omarchy-delorean-theme | MIT |
| `ember-n-ash` | https://github.com/Hydradevx/omarchy-ember-n-ash-theme | no LICENSE file |
| `event-horizon` | https://github.com/OldJobobo/omarchy-event-horizon-theme | no LICENSE file |
| `fireside` | https://github.com/bjarneo/omarchy-fireside-theme | no LICENSE file |
| `frankenstein` | https://github.com/twodogsdave/omarchy-frankenstein-theme | MIT |
| `ghost-pastel` | https://github.com/row-huh/omarchy-ghost-pastel-theme | no LICENSE file |
| `greek-noir` | https://github.com/HANCORE-linux/omarchy-greek-noir-theme | MIT |
| `gruvy-glass` | https://github.com/signaldirective/gruvy-glass | no LICENSE file |
| `harbordark` | https://github.com/HANCORE-linux/omarchy-harbordark-theme | MIT |
| `inkypinky` | https://github.com/HANCORE-linux/omarchy-inkypinky-theme | MIT |
| `kurayami` | https://github.com/bjornramberg/omarchy-kurayami-theme | GPL |
| `lowlight` | https://github.com/atif-1402/omarchy-lowlight-theme | no LICENSE file |
| `lunar` | https://github.com/pdfosborne/omarchy-lunar-theme | no LICENSE file |
| `mechanoonna` | https://github.com/HANCORE-linux/omarchy-mechanoonna-theme | MIT |
| `monokai` | https://github.com/bjarneo/omarchy-monokai-theme | no LICENSE file |
| `moon-orbit` | https://github.com/JJDizz1L/moon-orbit | MIT |
| `nagai-twilight` | https://github.com/mwaltzer/omarchy-nagai-twilight-theme | MIT |
| `nebulite` | https://github.com/atif-1402/omarchy-nebulite-theme | no LICENSE file |
| `oxford` | https://github.com/HANCORE-linux/omarchy-oxford-theme | MIT |
| `pmndrs` | https://github.com/leweyse/omarchy-pmndrs-theme | MIT |
| `reddcs` | https://github.com/mohamedredachakir/LINUX-OMARCHY-REDDCS | no LICENSE file |
| `reverie` | https://github.com/bjarneo/omarchy-reverie-theme | no LICENSE file |
| `roseofdune` | https://github.com/HANCORE-linux/omarchy-roseofdune-theme | MIT |
| `saga` | https://github.com/HANCORE-linux/omarchy-saga-theme | MIT |
| `sapphire` | https://github.com/HANCORE-linux/omarchy-sapphire-theme | MIT |
| `snow` | https://github.com/28bby/Snow-Theme | no LICENSE file |
| `soho` | https://github.com/bjarneo/omarchy-soho-theme | no LICENSE file |
| `synthwave84` | https://github.com/omacom-io/omarchy-synthwave84-theme | no LICENSE file |
| `thegreek` | https://github.com/HANCORE-linux/omarchy-thegreek-theme | MIT |
| `tycho` | https://github.com/leonardobetti/omarchy-tycho | MIT |
| `untitled` | https://github.com/niraletter/omarchy-untitled-theme | MIT |
| `vengeance` | https://github.com/Grey-007/vengeance | no LICENSE file |
| `vice-city` | https://github.com/lavarinimoreira/omarchy-vice-city-theme | no LICENSE file |
| `void` | https://github.com/vyrx-dev/omarchy-void-theme | MIT |
| `vurple` | https://github.com/tahfizhabib/omarchy-vurple-theme | no LICENSE file |
| `x-1632` | https://github.com/OldJobobo/omarchy-x-1632-theme | no LICENSE file |

## Vendor ports

Each package ported under [D017](../docs/decisions/D017-vendor-port-upstream-values.md) names the upstream palette file and the upstream app files it was built from.

| VGS theme | Palette file | App files | License |
|---|---|---|---|
| `horizon` | [jolaleye/horizon-theme-vscode, dark globals](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/src/dark/globals.json) | `apps/vscode-theme.json`: [themes/horizon.json](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/themes/horizon.json) at v2.0.2 | [MIT, © 2018 Jonathan Olaleye](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/LICENSE) |
| `horizon-light` | [jolaleye/horizon-theme-vscode, bright globals](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/src/bright/globals.json) | `apps/vscode-theme.json`: [themes/horizon-bright.json](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/themes/horizon-bright.json) at v2.0.2 | [MIT, © 2018 Jonathan Olaleye](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/LICENSE) |
| `catppuccin` | [catppuccin/kitty, mocha](https://github.com/catppuccin/kitty/blob/43098316202b84d6a71f71aaf8360f102f4d3f1a/themes/mocha.conf) | `apps/vscode-theme.json`: mocha.json in [Catppuccin.catppuccin-vsc 3.19.0](https://open-vsx.org/extension/Catppuccin/catppuccin-vsc/3.19.0); Neovim: [catppuccin/nvim](https://github.com/catppuccin/nvim/tree/e068ab5f8261f23f6f71ffd8791ae40315b77b9c) at `e068ab5`, vendored as `catppuccin` | [MIT, © 2021 Catppuccin](https://github.com/catppuccin/vscode/blob/catppuccin-vsc-v3.19.0/LICENSE) for the kitty, VS Code and Neovim repositories |
| `catppuccin-frappe` | [catppuccin/kitty, frappe](https://github.com/catppuccin/kitty/blob/43098316202b84d6a71f71aaf8360f102f4d3f1a/themes/frappe.conf) | `apps/vscode-theme.json`: frappe.json in [Catppuccin.catppuccin-vsc 3.19.0](https://open-vsx.org/extension/Catppuccin/catppuccin-vsc/3.19.0); Neovim: [catppuccin/nvim](https://github.com/catppuccin/nvim/tree/e068ab5f8261f23f6f71ffd8791ae40315b77b9c) at `e068ab5`, vendored as `catppuccin` | [MIT, © 2021 Catppuccin](https://github.com/catppuccin/vscode/blob/catppuccin-vsc-v3.19.0/LICENSE) for the kitty, VS Code and Neovim repositories |
| `catppuccin-macchiato` | [catppuccin/kitty, macchiato](https://github.com/catppuccin/kitty/blob/43098316202b84d6a71f71aaf8360f102f4d3f1a/themes/macchiato.conf) | `apps/vscode-theme.json`: macchiato.json in [Catppuccin.catppuccin-vsc 3.19.0](https://open-vsx.org/extension/Catppuccin/catppuccin-vsc/3.19.0); Neovim: [catppuccin/nvim](https://github.com/catppuccin/nvim/tree/e068ab5f8261f23f6f71ffd8791ae40315b77b9c) at `e068ab5`, vendored as `catppuccin` | [MIT, © 2021 Catppuccin](https://github.com/catppuccin/vscode/blob/catppuccin-vsc-v3.19.0/LICENSE) for the kitty, VS Code and Neovim repositories |
| `rose-pine-main` | [rose-pine/kitty, main](https://github.com/rose-pine/kitty/blob/efd4f01cb9887feaa7114ff21a887464295d0205/dist/rose-pine.conf) | `apps/vscode-theme.json`: rose-pine-color-theme.json in [mvllow.rose-pine 2.15.2](https://open-vsx.org/extension/mvllow/rose-pine/2.15.2); Neovim: [rose-pine/neovim](https://github.com/rose-pine/neovim/tree/ff483051a47e27d84bdef47703538df1ed9f4a47) at `ff48305`, vendored as `rose-pine` | [MIT, © Rosé Pine](https://github.com/rose-pine/vscode/blob/v2.15.2/LICENSE) for the kitty, VS Code and Neovim repositories |
| `rose-pine-moon` | [rose-pine/kitty, moon](https://github.com/rose-pine/kitty/blob/efd4f01cb9887feaa7114ff21a887464295d0205/dist/rose-pine-moon.conf) | `apps/vscode-theme.json`: rose-pine-moon-color-theme.json in [mvllow.rose-pine 2.15.2](https://open-vsx.org/extension/mvllow/rose-pine/2.15.2); Neovim: [rose-pine/neovim](https://github.com/rose-pine/neovim/tree/ff483051a47e27d84bdef47703538df1ed9f4a47) at `ff48305`, vendored as `rose-pine` | [MIT, © Rosé Pine](https://github.com/rose-pine/vscode/blob/v2.15.2/LICENSE) for the kitty, VS Code and Neovim repositories |

In the Horizon packages, every colour in `colors.toml`, `terminal-colors.toml`, `ui-roles.toml` and `apps/btop.theme` is a value from the matching globals file, unchanged. `apps/vscode-theme.json` is copied verbatim from the same MIT source at v2.0.2: [the upstream dark theme file](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/themes/horizon.json) for `horizon` and [the upstream bright theme file](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/themes/horizon-bright.json) for `horizon-light`. Its `colors` and `tokenColors` are the upstream values; only the file is pretty-printed and its top-level `name` is the VGS theme name. `test_horizon_packages_use_only_upstream_colours` in `scripts/check-vshell-helper.py` checks both.

For the `catppuccin`, `catppuccin-frappe`, `catppuccin-macchiato`, `rose-pine-main` and `rose-pine-moon` rows, [the VGS-318 audit](../docs/research/VGS-318-vendor-port-audit.md) compared `colors.toml` with the kitty file, `apps/vscode-theme.json` with the published theme file, and the vendored Neovim tree with the upstream commit. All three match. The audit did not cover their `apps/btop.theme`.
