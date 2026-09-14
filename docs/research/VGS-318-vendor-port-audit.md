# Findings: vendor-port theme audit against upstream palettes and app files

## Research Question

For each of the 24 vendor-port theme packages, do `colors.toml`, `apps/vscode-theme.json` and the Neovim colorscheme that `apps/neovim.lua` loads hold the values the vendor publishes, as [D017](../decisions/D017-vendor-port-upstream-values.md) requires? Which upstream files are official, at which pinned version, under which licence?

## Executive Summary

Five packages match their upstream in all three artefacts: `catppuccin`, `catppuccin-frappe`, `catppuccin-macchiato`, `rose-pine-main` and `rose-pine-moon`. They are added to the Vendor ports table in `themes/THEMES-ATTRIBUTION.md`.

The other 19 packages each have at least one departure. A departure is one of three kinds: a palette slot that differs, a VS Code key that differs, or an app file shipped where the vendor publishes none. Every curated VS Code file that has an official upstream equals a published upstream version, except `flexoki-light` (6 keys) and `eldritch` (1 key). Every vendored Neovim tree equals a commit of the plugin repository it names in its colour files; only `monokai-pro-gthelding` changes colour values. Six packages use a community Neovim port where the vendor publishes an official Vim colorscheme.

Two licences block redistribution. `ristretto` ships the proprietary Monokai Pro VS Code theme, whose licence says it "may not be sub-licensed, resold, or redistributed". The vendored `vim-synthwave84` has no licence file.

## Key Findings

- `colors.toml` matches the vendor's terminal file in 11 packages. It diverges in 13, from 1 key (`kanagawa`, `matte-black`, `eldritch`) to 18 keys (`gruvbox`).
- `gruvbox/colors.toml` is not a morhetz gruvbox palette. 19 of its 21 terminal values and its accent appear in the vendored gruvbox-material palette file.
- `tokyo-night-storm/colors.toml` equals folke/tokyonight.nvim's storm kitty file on all 21 keys. It differs from enkia's VS Code terminal colours on 13 keys. `tokyo-night/colors.toml` matches neither: 12 keys differ from enkia and 14 from folke.
- `ristretto/apps/vscode-theme.json` equals Monokai Pro 2.0.13 `Monokai Pro (Filter Ristretto).json` exactly. The current Monokai Pro 2.0.15 adds 9 keys the VGS file lacks.
- `ayu/apps/vscode-theme.json` equals ayu's `ayu-dark-unbordered.json` in teabyii.ayu 1.1.9, 1.1.11 and 1.1.12. Against the bordered `ayu-dark.json`, 14 `colors` keys differ.
- Six packages ship a curated VS Code file where the vendor publishes no VS Code theme: `gruvbox`, `tokyo-night-moon`, `kanagawa`, `kanagawa-dragon`, `osaka-jade` and `miasma`. `gruvbox`'s file equals the community extension jdinhlife.gruvbox 1.29.1.
- Every diff-colour overlay in a dark vendor port (`kanagawa-dragon`, `matte-black`, `miasma`, `synthwave84`) holds values that appear in no listed upstream file. The same holds for 7 of the 8 values in the `catppuccin-latte` and `rose-pine` light overlays.
- The vendored `monokai-pro-gthelding` tree is loctvl842/monokai-pro.nvim at `7320126` with 4 files changed. Two of those changes are colour values. Its source repository, gthelding/monokai-pro.nvim, no longer resolves on GitHub.

## Evidence and Sources

### Results by package

Status words: **matches** (no differing key or file), **diverges (N)** (N differing keys, slots or files), **no official source** (the vendor publishes no file for that app), **community port** (the vendor publishes an official file but the package loads a third-party one). The Neovim column is the vendored tree under `config/vshell/nvim/colorschemes/` that `apps/neovim.lua` names. The `apps/neovim.lua` spec itself holds no colour values.

| Package | `colors.toml` | `apps/vscode-theme.json` | Neovim colorscheme |
|---|---|---|---|
| `catppuccin` | matches | matches | matches |
| `catppuccin-frappe` | matches | matches | matches |
| `catppuccin-latte` | diverges (4) | matches | matches |
| `catppuccin-macchiato` | matches | matches | matches |
| `dracula` | matches | matches | community port |
| `gruvbox` | diverges (18) | no official source | community port |
| `nord` | matches | matches | community port (nordfox) |
| `tokyo-night` | diverges (12) | matches | no official source |
| `tokyo-night-storm` | diverges (13) | matches | no official source |
| `tokyo-night-moon` | matches | no official source | matches, 2 non-colour files differ |
| `rose-pine` | matches | matches | matches |
| `rose-pine-main` | matches | matches | matches |
| `rose-pine-moon` | matches | matches | matches |
| `everforest` | diverges (2) | matches | community port |
| `kanagawa` | diverges (1) | no official source | matches |
| `kanagawa-dragon` | matches | no official source | matches |
| `ayu` | diverges (2) | matches | community port |
| `flexoki-light` | diverges (11) | diverges (6) | matches |
| `ristretto` | diverges (15) | diverges (9); licence forbids redistribution | no official source; vendored fork diverges (2 colour values) |
| `matte-black` | diverges (1) | matches | matches |
| `osaka-jade` | matches | no official source | no official source |
| `eldritch` | diverges (1) | diverges (1) | matches |
| `miasma` | diverges (4) | no official source | community port |
| `synthwave84` | diverges (12) | matches | no official source; no licence file |

### Differing keys

- `catppuccin-latte/colors.toml`: `color0` `#bcc0cc` (upstream `#5c5f77`), `color7` `#5c5f77` (`#acb0be`), `color8` `#acb0be` (`#6c6f85`), `color15` `#6c6f85` (`#bcc0cc`).
- `gruvbox/colors.toml`: 17 mapped keys differ from morhetz gruvbox dark, medium contrast: `foreground`, `selection_background`, `color0` to `color12`, `color14` and `color15`. Example: `color1` `#ea6962` (upstream `#cc241d`). The accent `#7daea3` appears in no gruvbox.vim value.
- `tokyo-night/colors.toml` against enkia 1.1.2: `foreground`, `background`, `color0`, `color2`, `color5`, `color6`, `color8`, `color9`, `color10`, `color11`, `color12`, `color14`.
- `tokyo-night-storm/colors.toml` against enkia 1.1.2: `foreground`, `background`, `color0`, `color2`, `color7`, `color9` to `color15`, and `selection_background` `#2e3c64`, which no listed upstream file holds.
- `everforest/colors.toml`: `color0` `#475258` (upstream `#343f44`), `color8` `#475258` (`#859289`).
- `kanagawa/colors.toml`: `color0` `#090618` (upstream `#16161d`).
- `ayu/colors.toml`: `background` `#0b0e14` (upstream `#0d1017`); `selection_background` `#1b3a5b` appears in no listed upstream file.
- `flexoki-light/colors.toml`: `color0`, `color4`, `color7` to `color15`. The package swaps the normal and bright slots: `color4` `#205ea6` where upstream has `#4385be`, and `color12` the reverse.
- `flexoki-light/apps/vscode-theme.json`: lacks `sideBar.activeBackground`, `sideBar.activeForeground`, `sideBar.fileIcon.foreground`, `sideBar.folderIcon.foreground`, `sideBar.hoverBackground`, `sideBar.hoverForeground`.
- `ristretto/colors.toml` against Monokai Pro 2.0.15: `foreground`, `background`, `cursor`, `color0`, `color7` to `color15`; `selection_foreground` and `selection_background` appear in no listed upstream file.
- `ristretto/apps/vscode-theme.json` against 2.0.15: lacks `agentSessionReadIndicator.foreground`, `agentSessionSelectedBadge.border`, `agentSessionSelectedUnfocusedBadge.border`, `aiCustomizationManagement.sashBorder` and the five `markdownAlert.*.foreground` keys.
- `monokai-pro-gthelding` against loctvl842 `7320126`: `palette/ristretto.lua` `text` `#e6d9db` (upstream `#fff1f3`); `theme/editor.lua` `CursorColumn` background `editor.background` (upstream `editor.lineHighlightBackground`); two files lose a trailing blank line.
- `matte-black/colors.toml`: `selection_background` `#515151` (upstream `#333333`).
- `eldritch/colors.toml`: `cursor` `#f8f8f2` (upstream `#37f499`).
- `eldritch/apps/vscode-theme.json`: `tab.hoverBackground` `#7081d033` (upstream `#7081d0` at eldritch-theme/vscode `fb6640b`). Open VSX 1.0.10 predates the upstream `sideBar.foreground` restore, so 2 keys differ there.
- `miasma/colors.toml`: `selection_foreground` `#c2c2b0` (upstream `#000000`), `selection_background` `#78824b` (`#e4c47a`), `color0` `#222222` (`#000000`), `color7` `#c2c2b0` (`#d7c483`).
- `synthwave84/colors.toml`: 9 mapped keys differ (`cursor`, `color1`, `color2`, `color4`, `color5`, `color9`, `color10`, `color11`, `color12`); `background` `#240037`, `selection_background` `#543863` and the accent `#8f00ff` appear in no listed upstream file.
- `tokyonight.nvim` against folke `cdc07ac`: `scripts/build` and `scripts/docs` change `#!/bin/env bash` to `#!/usr/bin/env bash`.
- `gruvbox.nvim` adds the generated `doc/tags`; `nightfox.nvim` omits `.github/workflows/docs.yml.bak`. Neither file holds colours.
- `miasma.nvim` equals OldJobobo/miasma.nvim `466456f`, a CC0 fork. Against every commit of xero/miasma.nvim, at least 35 files are modified or added.

### Terminal slot overlays

D017 lists the VGS-290 overlays as pending this audit. VGS-290 wrote the `kanagawa-dragon`, `matte-black`, `miasma` and `synthwave84` overlays; VGS-289 wrote the `catppuccin-latte`, `rose-pine` and `flexoki-light` overlays. They compare with the same upstream terminal files:

| Package | Overlay keys | Differ from upstream slot | In no listed upstream file |
|---|---|---|---|
| `catppuccin-latte` | 4 | 4 | 3 |
| `rose-pine` | 4 | 4 | 4 |
| `kanagawa-dragon` | 1 | 1 | 1 |
| `flexoki-light` | 1 | 0 | 0 |
| `matte-black` | 3 | 3 | 3 |
| `miasma` | 2 | 2 | 2 |
| `synthwave84` | 1 | 1 | 1 |

The Horizon `apps/btop.theme` and the VGS-286 `apps/claude-light.json` files are outside the 24 packages.

### Upstream sources

Each row names the file the comparison read. A git pin is the commit a clone resolved on 2026-09-14. An Open VSX pin is the published package version; its SHA-256 prefix is given where the run printed one.

| Package family | Palette reference | VS Code reference | Neovim reference | Licences |
|---|---|---|---|---|
| catppuccin | [catppuccin/kitty](https://github.com/catppuccin/kitty/tree/43098316202b84d6a71f71aaf8360f102f4d3f1a) `themes/<flavour>.conf` | Open VSX Catppuccin.catppuccin-vsc 3.19.0 (`ebf347664837edbe`), tag `catppuccin-vsc-v3.19.0`, `themes/<flavour>.json` | [catppuccin/nvim](https://github.com/catppuccin/nvim/tree/e068ab5f8261f23f6f71ffd8791ae40315b77b9c) | MIT ×3 |
| dracula | [dracula/kitty](https://github.com/dracula/kitty/tree/87717a3f00e3dff0fc10c93f5ff535ea4092de70) `dracula.conf` | Open VSX dracula-theme.theme-dracula 2.25.1 (`f4d8c28fc64874b1`), `theme/dracula.json` | official [dracula/vim](https://github.com/dracula/vim/tree/e7817b4baccfb3529f709ac048c621f35cdbc5b3); loaded [Mofiqul/dracula.nvim](https://github.com/Mofiqul/dracula.nvim/tree/ae752c13e95fb7c5f58da4b5123cb804ea7568ee) | MIT ×4 |
| gruvbox | [morhetz/gruvbox](https://github.com/morhetz/gruvbox/tree/5d15b2765f59754d7ac263c88a0f6e3e58124951) `colors/gruvbox.vim` | none official; file equals Open VSX jdinhlife.gruvbox 1.29.1 (`8fd3166439d3bdc4`) | official morhetz/gruvbox; loaded [ellisonleao/gruvbox.nvim](https://github.com/ellisonleao/gruvbox.nvim/tree/154eb5ff5b96d0641307113fa385eaf0d36d9796) | morhetz: no LICENSE file, `package.json` says MIT; others MIT |
| nord | [nordtheme/alacritty](https://github.com/nordtheme/alacritty/tree/9949642f3903e8fcb62bfc03f09410e3d78440c2) `src/nord.yaml` | Open VSX arcticicestudio.nord-visual-studio-code 0.19.0 (`7f0b03922471232b`) | official [nordtheme/vim](https://github.com/nordtheme/vim/tree/f13f5dfbb784deddbc1d8195f34dfd9ec73e2295); loaded [EdenEast/nightfox.nvim](https://github.com/EdenEast/nightfox.nvim/tree/4dacd3f0185a2227bdf3b6c0975a8f0bf87cac9a) `nordfox` | MIT ×4 |
| tokyo-night, tokyo-night-storm | Open VSX enkia.tokyo-night 1.1.2 (`79aaf590d5ad65ef`) `terminal.*` keys | same package | none official; loaded [folke/tokyonight.nvim](https://github.com/folke/tokyonight.nvim/tree/cdc07ac78467a233fd62c493de29a17e0cf2b2b6) | enkia MIT; folke Apache-2.0 |
| tokyo-night-moon | folke/tokyonight.nvim `extras/kitty/tokyonight_moon.conf` | none official | folke/tokyonight.nvim | Apache-2.0 |
| rose-pine | [rose-pine/kitty](https://github.com/rose-pine/kitty/tree/efd4f01cb9887feaa7114ff21a887464295d0205) `dist/*.conf` | Open VSX mvllow.rose-pine 2.15.2 (`cd0b96b878258a0e`), tag `v2.15.2` | [rose-pine/neovim](https://github.com/rose-pine/neovim/tree/ff483051a47e27d84bdef47703538df1ed9f4a47) | MIT ×3 |
| everforest | Open VSX sainnhe.everforest 0.3.0 (`5f5bdab54200099d`) `terminal.*` keys | same package, `themes/everforest-dark.json` | official [sainnhe/everforest](https://github.com/sainnhe/everforest/tree/85a86eb62409e3ec88713bff3d1b9d7374e112e4); loaded [neanias/everforest-nvim](https://github.com/neanias/everforest-nvim/tree/d235ca0aa6a29546e661a020e2618612acbbffbe) | MIT ×3 |
| kanagawa | [rebelot/kanagawa.nvim](https://github.com/rebelot/kanagawa.nvim/tree/bb85e4bfc8d89b0e62c8fa53ccdd13d12e2f77b3) `extras/kitty/kanagawa.conf`, `kanagawa_dragon.conf` | none official | rebelot/kanagawa.nvim | MIT |
| ayu | Open VSX teabyii.ayu 1.1.12 (`d95080ce43e9ad13`) `terminal.*` keys | same package, `ayu-dark-unbordered.json` | official [ayu-theme/ayu-vim](https://github.com/ayu-theme/ayu-vim/tree/01faacb4cb76e8cf72ad9858c581d80876260ab3); loaded [Shatur/neovim-ayu](https://github.com/Shatur/neovim-ayu/tree/e5a9f0fa2918d6b5f57c21b3ac014314ee5e41c8) | ayu MIT; ayu-vim Apache-2.0; neovim-ayu GPL-3.0 |
| flexoki-light | [kepano/flexoki](https://github.com/kepano/flexoki/tree/8d723bac4a9ac46adfdf99d42155286977aac72a) `kitty/flexoki_light.conf` | kepano/flexoki `vscode/Flexoki-Light-color-theme.json` | [kepano/flexoki-neovim](https://github.com/kepano/flexoki-neovim/tree/c3e2251e813d29d885a7cbbe9808a7af234d845d) | MIT ×2 |
| ristretto | Open VSX monokai.theme-monokai-pro-vscode 2.0.15 (`4b41a5945036cd98`) | same package, `themes/Monokai Pro (Filter Ristretto).json` | none official; fork of [loctvl842/monokai-pro.nvim](https://github.com/loctvl842/monokai-pro.nvim/tree/73201266640a44f700a32a254fedf2ebcf65c316) | Monokai Pro proprietary, forbids redistribution; loctvl842 MIT |
| matte-black | [tahayvr/matte-black-theme](https://github.com/tahayvr/matte-black-theme/tree/9735fcc87ba148e1fcd7a2c6f2805e0006c7a28d) `matte-black/alacritty.toml` | Open VSX TahaYVR.matteblack 1.0.3 (`787186c5c8510a95`) | [tahayvr/matteblack.nvim](https://github.com/tahayvr/matteblack.nvim/tree/a8a039f5d6189b28d76fa0221e64965efec7e996) | matte-black-theme: no licence file; VS Code and Neovim MIT |
| osaka-jade | [Justikun/omarchy-osaka-jade-theme](https://github.com/Justikun/omarchy-osaka-jade-theme/tree/871a400517d207b10ac0dd7ef34862a12f3ebd26) `alacritty.toml`, `kitty.conf` | none; the vendor's `vscode.json` names jovejonovski.ocean-green, a different theme | none; the vendor's `neovim.lua` loads [ribru17/bamboo.nvim](https://github.com/ribru17/bamboo.nvim/tree/1309bc88bffcf1bedc3e84e7fa9004de93da774a), a different theme | MIT ×2 |
| eldritch | [eldritch-theme/kitty](https://github.com/eldritch-theme/kitty/tree/11f7a63c19bebe765a665a11e2ff1dd697e398cd) `Eldritch.conf` | [eldritch-theme/vscode](https://github.com/eldritch-theme/vscode/tree/fb6640b31f479fd0d90ec6899c3da1772172f209) `themes/eldritch.json` | [eldritch-theme/eldritch.nvim](https://github.com/eldritch-theme/eldritch.nvim/tree/c9131a5a11f00a2f428f563a4eb2c4aeb680d963) | MIT ×3 |
| miasma | [xero/miasma.nvim](https://github.com/xero/miasma.nvim/tree/627f2e1cac91de0d1d4dd7472b506a30f41b2b7d) `extras/miasma.ghostty` | none official | official xero/miasma.nvim; loaded fork [OldJobobo/miasma.nvim](https://github.com/OldJobobo/miasma.nvim/tree/466456f08d1a114c983c0d24e8fc01339e3b0a27) | CC0-1.0 ×2 |
| synthwave84 | Open VSX RobbOwen.synthwave-vscode 0.1.20 (`223278311ceaf2b7`) `terminal.*` keys | same package | none official; loaded [artanikin/vim-synthwave84](https://github.com/artanikin/vim-synthwave84/tree/a5caa80d9e1a7021f9ec6c06a96d09dfc2d99ed1) | RobbOwen MIT; artanikin no licence file |

### Licence evidence

- Monokai Pro 2.0.15 `LICENSE`, in the published package: "Monokai Pro may not be sub-licensed, resold, or redistributed." The same terms are at [monokai.pro/license](https://monokai.pro/license). VGS ships the theme's VS Code file verbatim as `themes/ristretto/apps/vscode-theme.json`.
- artanikin/vim-synthwave84 has no licence file at `a5caa80`. Without one, the author grants no right to redistribute. VGS ships the tree as `config/vshell/nvim/colorschemes/vim-synthwave84`.
- tahayvr/matte-black-theme has no licence file at `9735fcc`. VGS copies no file from it; `colors.toml` holds its colour values only.
- Shatur/neovim-ayu is GPL-3.0. The vendored tree keeps `COPYING`, which the licence requires.

### Provenance lookups

- The Matte Black VS Code extension is TahaYVR.matteblack ([Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=TahaYVR.matteblack)), by the theme's author ([tahayvr on GitHub](https://github.com/tahayvr)).
- Kanagawa VS Code themes are community ports, for example [metaphore.kanagawa-vscode-color-theme](https://open-vsx.org/extension/metaphore/kanagawa-vscode-color-theme). rebelot/kanagawa.nvim publishes no VS Code theme under `extras/`.
- Miasma's palette and first Neovim theme are xero's ([xero/miasma.nvim](https://github.com/xero/miasma.nvim)). VS Code ports are third-party ([OldJobobo/omarchy-miasma-theme](https://github.com/OldJobobo/omarchy-miasma-theme)).
- Osaka Jade is Justin Lowry's Omarchy theme ([Justikun/omarchy-osaka-jade-theme](https://github.com/Justikun/omarchy-osaka-jade-theme)).

## Tradeoffs / Alternatives

- **Vendor for tokyo-night and tokyo-night-storm.** This audit treats enkia/tokyo-night-vscode-theme as the vendor, because Tokyo Night and Tokyo Night Storm began as enkia's VS Code theme. folke/tokyonight.nvim is then a port. Taking folke as the vendor instead gives a Neovim match for both packages and a `colors.toml` match for `tokyo-night-storm`. `tokyo-night` still diverges on 14 keys, and the enkia VS Code files still match. The choice changes which follow-up applies. It goes to the owner through the follow-up proposals.
- **Community port against no Neovim file.** D017 says a package ships no file where the upstream publishes none. Where the vendor publishes a Vim colorscheme (dracula, gruvbox, nord, everforest, ayu, miasma), the package can load that file instead of the community Lua port. Where the vendor publishes none (tokyo-night under enkia, ristretto, osaka-jade, synthwave84), D017 removes the Neovim theme and the generated render stands.
- **Palette reference.** The comparison uses the vendor's terminal file, because `colors.toml` keys are terminal keys. For everforest, ayu, ristretto, synthwave84 and enkia's Tokyo Night, the vendor's VS Code `terminal.*` keys are the only published terminal colours.

## Recommendation / Decision Criteria

- Add only the five fully matching packages to the Vendor ports table. This commit does that.
- File one follow-up per departing package from `tmp/audit-issues-VGS-318.json`. Each follow-up takes its values from the pinned upstream file this report names.
- Treat `ristretto` first. Its VS Code file is redistributed against its licence. D017's Revisit When names this case.
- Treat `synthwave84` next. Its vendored Neovim tree has no licence grant.

### Follow-up proposals

One proposal per departing package. `tmp/audit-issues-VGS-318.json` carries each one with its requirements, reach and labels for the TPM pipeline. Priority 3 unless noted.

1. `catppuccin-latte`: set `color0`, `color7`, `color8`, `color15` to the catppuccin/kitty latte values; limit the terminal overlay to upstream values.
2. `dracula`: load dracula/vim in place of Mofiqul/dracula.nvim.
3. `gruvbox`: rebuild `colors.toml` from morhetz/gruvbox; remove `apps/vscode-theme.json`; load morhetz/gruvbox in Neovim.
4. `nord`: load nordtheme/vim in place of nightfox `nordfox`.
5. `tokyo-night` (owner-gated): the owner picks enkia or folke as vendor; `colors.toml` and app files follow that vendor.
6. `tokyo-night-storm` (owner-gated): apply the same vendor choice.
7. `tokyo-night-moon`: remove `apps/vscode-theme.json`.
8. `rose-pine`: limit the terminal overlay to rose-pine/kitty dawn values.
9. `everforest`: set `color0` and `color8` to upstream; load sainnhe/everforest in Neovim.
10. `kanagawa`: set `color0` to upstream; remove `apps/vscode-theme.json`.
11. `kanagawa-dragon`: limit the terminal overlay to upstream values; remove `apps/vscode-theme.json`.
12. `ayu`: set `background` and `selection_background` to upstream; load ayu-theme/ayu-vim in Neovim.
13. `flexoki-light`: rebuild `colors.toml` from the Flexoki kitty file; restore the 6 missing VS Code keys.
14. `ristretto` (priority 2, owner-gated): remove the Monokai Pro VS Code file from the package and release archives; the owner decides whether the package stays a vendor port.
15. `matte-black`: set `selection_background` to upstream; limit the terminal overlay to upstream values.
16. `osaka-jade`: remove `apps/vscode-theme.json` and `apps/neovim.lua`.
17. `eldritch`: set `cursor` and VS Code `tab.hoverBackground` to upstream.
18. `miasma`: rebuild `colors.toml` from xero's ghostty file; limit the overlay to upstream values; remove `apps/vscode-theme.json`; load xero/miasma.nvim.
19. `synthwave84` (priority 2): remove the unlicensed `vim-synthwave84` tree and `apps/neovim.lua`; set `colors.toml` keys to upstream where upstream sets them.

## Risks / Unknowns

- Terminal slot mapping is the vendor's own only where the vendor publishes a terminal file. For gruvbox, the mapping comes from `g:terminal_color_*` in `colors/gruvbox.vim` with dark background and medium contrast, which `apps/neovim.lua` does not set.
- The accent key has no terminal slot. The audit checks only that its value appears in a listed upstream file, not that the vendor uses it as an accent.
- sainnhe.everforest regenerates its theme from user settings at runtime. The comparison reads the default file in the published package.
- `config/vshell/nvim/colorschemes/ATTRIBUTION.md` lists the catppuccin licence as `—`, but the vendored tree carries `LICENSE.md` (MIT).
- The gthelding/monokai-pro.nvim repository does not resolve, so its own history is not available. The comparison used the loctvl842 parent.

## Revisit Conditions

- An upstream publishes a new release of a file this report pins.
- The owner picks folke as the Tokyo Night vendor.
- A checker covers every vendor-port package, which D017 lists as its own revisit condition.

## Research Metadata

- Mode: local repository comparison. No Exa research ran, so there is no provider sidecar. Web search answered only the provenance lookups above.
- Sources: shallow clones of the palette, terminal and VS Code repositories, full-history clones with blobs omitted of the Neovim plugin repositories, and the Open VSX packages in the sources table, plus Monokai Pro 2.0.5 to 2.0.14 and teabyii.ayu 1.1.1 to 1.1.11 for the version search. All live under the worktree's ignored `tmp/`.
- `colors.toml`: each of the 21 terminal keys (`foreground`, `background`, `cursor`, `selection_foreground`, `selection_background`, `color0` to `color15`) compares with the upstream terminal file's value for that key, hex lowercased. A key the upstream file does not set is checked for membership in the hex set of every listed reference file for that package. The count is differing keys, plus unset keys whose value appears in no reference file, plus one when the accent appears in none.
- `apps/vscode-theme.json`: both files parse as JSON with comments, hex lowercased. The count is `colors` keys that change, exist only in VGS, or exist only upstream, plus the same for `semanticTokenColors` and for (scope, setting) pairs of `tokenColors`. Key order, whitespace and the top-level `name` are ignored. A second case-sensitive pass gives the same counts; every compared `tokenColors` list is identical. The Dracula file adds `"type": "dark"`, which names no colour.
- Neovim: in the upstream clone, `GIT_INDEX_FILE=<tmp> git --work-tree=config/vshell/nvim/colorschemes/<dir> add -A -f .` then `git write-tree` stages the vendored tree. `git diff-tree -r --no-renames --name-status <commit> <tree>` then runs for every commit on the default branch. The report names the commit with the fewest modified plus added files; `D` rows are upstream files the vendored copy omits.
