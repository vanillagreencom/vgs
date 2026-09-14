# Findings: community-import theme audit against upstream palettes and app files

## Research Question

For each community-import package in `themes/THEMES-ATTRIBUTION.md`, do `colors.toml`, `terminal-colors.toml`, `ui-roles.toml` and every colour-bearing app file hold only values the upstream repository publishes, as [D017](../decisions/D017-vendor-port-upstream-values.md) requires? Which upstream commit do they match, under which licence? For the ten shipped packages with no attribution row, does an upstream exist, or is the package VGS-original?

## Executive Summary

All 45 audited packages depart from their upstream in at least one colour-bearing file, so this audit adds no row to `themes/THEMES-ATTRIBUTION.md`. The 46th table row, `synthwave84`, is covered by [VGS-318](VGS-318-vendor-port-audit.md).

Most files VGS copied from the upstream repositories match. `colors.toml` equals the upstream terminal palette at the closest upstream commit in 35 of 45 packages; keys no upstream terminal file sets are listed as unverified by role, not as matches. `apps/btop.theme` is a verbatim upstream copy in all 44 packages that ship one, and `apps/chromium.theme` matches in all 38 that ship one. No audited package ships `ui-roles.toml`.

The departures are mostly files VGS wrote. `apps/vscode-theme.json` departs in 43 packages, the Aether Neovim spec in `apps/neovim.lua` in 25, the VGS-290 terminal overlays in 18, and the VGS-286 `apps/claude-light.json` in 6. Ten `colors.toml` keys and the five hand-written `roseofdune` terminal files complete the list.

23 upstream repositories have no licence file, and VGS ships a verbatim `btop.theme` from 22 of them. None of the ten unattributed packages is VGS-original: eight come from basecamp/omarchy, `bauhaus` from mwaltzer/omarchy-bauhaus-theme, and `noctalia` ports the Noctalia shell's default palette.

## Key Findings

- All 43 departing VS Code files share one key set: 664 `colors` keys, 69 `tokenColors` entries and 24 `semanticTokenColors` keys. Each holds 12 to 74 values that appear in no file of its upstream repository. Only `mechanoonna` (the upstream's own theme file) and `arc-blueberry` (Bearded Theme 10.1.0) match.
- In 23 packages the upstream publishes no VS Code theme, and in 14 more its `vscode.json` only names a Marketplace extension or a placeholder. D017 says the generated render stands in both cases. In the remaining 6, the upstream's own theme file differs from the VGS file in 199 to 875 keys.
- The 25 packages that load `aether.nvim` pass 5 to 7 colours the upstream never published, under the keys `dark_bg`, `darker_bg`, `lighter_bg`, `dark_fg`, `light_fg`, `brown`, and in 2 packages each `selection_background` and `accent`. The vendored `aether.nvim` tree itself equals bjarneo/aether.nvim `02af9ba`.
- The 18 terminal overlays set 40 keys; 39 of those values appear in no upstream file. The four D017 examples are confirmed: `color2` is `#68985d` in `akane`, `#357e22` in `arc-raiders`, `#3dad1b` in `greek-noir` and `#4aa833` in `harbordark`.
- The six `apps/claude-light.json` files hold 36 diff colours. None is in an upstream file, and no upstream ships a Claude Code theme.
- Ten `colors.toml` files hold a value the upstream does not publish for its slot. Four `selection_background` values and three `accent` values appear in no upstream file. `amberbyte`'s `selection_foreground` and `archwave`'s `selection_background` differ from every upstream terminal file that sets the slot. `roseofdune` sets `accent` to an upstream value that the upstream uses in another slot.
- 17 packages set a `colors.toml` key that no upstream terminal file sets, to a value found in another upstream file. The audit cannot confirm the role, so it reports these keys as unverified by role.
- The Horizon `apps/btop.theme` question needs an owner decision. Both Horizon btop files and the generated btop render hold only `colors.toml` values; each hand-written file differs from its render in 5 of 42 keys.
- 31 of the 45 packages record `contrastShortfalls` on the VGS-328 branch. Their follow-ups may record a shortfall and may not change a colour to clear it.

## Evidence and Sources

### Scope

- `themes/THEMES-ATTRIBUTION.md` lists 46 community-import packages. `synthwave84` is also one of VGS-318's 24 vendor ports, and VGS-318 wrote its row, so this report writes none. Against omacom-io/omarchy-synthwave84-theme at [`283dbcf`](https://github.com/omacom-io/omarchy-synthwave84-theme/tree/283dbcf17c3a500b7d3ddfce081e1dc2b3641172), its `colors.toml` differs only in `selection_background` `#543863`, and its `apps/btop.theme` is a verbatim copy of the upstream `btop.theme`, a file VGS-318 did not compare.
- Colour-bearing files compared: `colors.toml` (every package), `terminal-colors.toml` (18), `apps/btop.theme` (44), `apps/chromium.theme` (38), `apps/neovim.lua` and the vendored tree it loads (45), `apps/vscode-theme.json` (45), `apps/claude-light.json` (6), and `roseofdune`'s `apps/alacritty.toml`, `apps/kitty.conf`, `apps/ghostty.conf`, `apps/foot.ini` and `apps/wezterm.lua`. Only the two Horizon packages ship `ui-roles.toml`. `apps/icons.theme` names an icon theme and `theme.json` names no colour, so D017 does not govern either.

### Results by package

Status words: **matches** (every colour value equals the upstream file for the same app; **verbatim** means the text is identical apart from blank lines, trailing whitespace and case), **diverges (N)** (N differing keys or values), **overlay** (a VGS-written `terminal-colors.toml`), **no upstream file** (the upstream repository publishes no file for that app), **upstream names X** (the upstream's `vscode.json` names a Marketplace extension or a placeholder, not a theme file). For `apps/neovim.lua`, **values match** is a role check, stated under Research Metadata. "Values in no upstream file" counts distinct colour values found in no text file of the upstream repository at the closest commit.

| Package | Closest commit | `colors.toml` | `terminal-colors.toml` | `apps/btop.theme` | `apps/chromium.theme` | `apps/neovim.lua` and vendored tree | `apps/vscode-theme.json` | Other colour files |
|---|---|---|---|---|---|---|---|---|
| `akane` | `8ab3d02` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | values match; inline, no vendored tree | diverges (740) from `vscode-extension/themes/akane-color-theme.json` | `apps/claude-light.json`: no upstream file; 6 of 6 values in no upstream file |
| `amberbyte` | `8ea68b3` | diverges (1) | not shipped | matches, verbatim | matches | values match; `matteblack.nvim` matches (VGS-318) | upstream names `TahaYVR.matteblack`; 45 values in no upstream file | none |
| `arc-blueberry` | `3476e99` | diverges (1) | not shipped | matches, verbatim | matches | values match; inline, no vendored tree | matches Open VSX BeardedBear.beardedtheme 10.1.0 | none |
| `arc-raiders` | `f0cfc37` | matches | overlay (4 keys, 4 in no upstream file) | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 57 values in no upstream file | none |
| `archwave` | `b3e6b81` | diverges (1) | not shipped | matches, verbatim | matches | values match; `tokyonight.nvim` matches, 2 non-colour script files differ (VGS-318) | no upstream file; 52 values in no upstream file | `apps/claude-light.json`: no upstream file; 6 of 6 values in no upstream file |
| `artzen` | `d425535` | diverges (1) | not shipped | matches, verbatim | matches | diverges (7 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 62 values in no upstream file | none |
| `biscuit-de-mar` | `bdec74a` | matches | overlay (1 keys, 1 in no upstream file) | matches, verbatim | matches | values match; `biscuit.nvim` matches Biscuit-Theme/nvim `1307d87`; no licence file | upstream names `oldjobobo.biscuit-theme`; 57 values in no upstream file | none |
| `brutalism` | `21c9887` | matches | not shipped | matches, verbatim | matches | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 61 values in no upstream file | none |
| `coppernight` | `5a2380a` | matches | not shipped | matches, verbatim | matches | values match; inline, no vendored tree | no upstream file; 55 values in no upstream file | none |
| `cpunk` | `c4d726b` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 55 values in no upstream file | none |
| `delorean` | `41de4ca` | matches | not shipped | matches, verbatim | matches | values match; `tokyonight.nvim` matches, 2 non-colour script files differ (VGS-318) | upstream names `Pustur.retrowave-theme`; 71 values in no upstream file | none |
| `ember-n-ash` | `dcb94c8` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | not shipped | values match; inline, no vendored tree | no upstream file; 58 values in no upstream file | none |
| `event-horizon` | `d0f689b` | matches | not shipped | matches, verbatim | matches | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | upstream names `mcagampan.dark-horizon`; 55 values in no upstream file | none |
| `fireside` | `74b5633` | matches | not shipped | matches, verbatim | not shipped | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 55 values in no upstream file | none |
| `frankenstein` | `94f7995` | matches | not shipped | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | diverges (199) from `vscode-extension/themes/aether-color-theme.json` | `apps/claude-light.json`: no upstream file; 6 of 6 values in no upstream file |
| `ghost-pastel` | `d8e1b55` | matches | not shipped | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | upstream names `rokage.ghost-pastel`; 55 values in no upstream file | none |
| `greek-noir` | `4dde93c` | matches | overlay (4 keys, 4 in no upstream file) | matches, verbatim | matches | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | upstream names `hrose.amp-theme`; 54 values in no upstream file | none |
| `gruvy-glass` | `1204ee7` | matches | not shipped | matches, verbatim | not shipped | values match; `gruvbox.nvim` matches, adds `doc/tags` (VGS-318) | upstream names `jdinhlife.gruvbox`; 53 values in no upstream file | none |
| `harbordark` | `5203f4d` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | diverges (536) from `vscode-extension/themes/harbordark-color-theme.json` | none |
| `inkypinky` | `1e5e799` | matches | not shipped | matches, verbatim | matches | values match; `lake-dweller.nvim` matches yonatanperel/lake-dweller.nvim `67e0048` | upstream names `AlexDo.catppuccin-noir`; 58 values in no upstream file | none |
| `kurayami` | `96a3250` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 55 values in no upstream file | none |
| `lowlight` | `c685f81` | matches | overlay (3 keys, 3 in no upstream file) | matches, verbatim | matches | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 61 values in no upstream file | none |
| `lunar` | `a31285f` | diverges (1) | not shipped | matches, verbatim | matches | values match; inline, no vendored tree | upstream names `philiposborne.eva-plus-theme`; 54 values in no upstream file | none |
| `mechanoonna` | `9ec02da` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | values match; `gruvbox-material` matches sainnhe/gruvbox-material `11d779b` | matches `vscode-extension/themes/mechanoonna-color-theme.json` | none |
| `monokai` | `7a947e1` | matches | not shipped | matches, verbatim | matches | values match; `monokai-pro.nvim` matches loctvl842/monokai-pro.nvim `a68e38b` | no upstream file; 64 values in no upstream file | none |
| `moon-orbit` | `60c4d32` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 51 values in no upstream file | `apps/claude-light.json`: no upstream file; 6 of 6 values in no upstream file |
| `nagai-twilight` | `b101d8a` | matches | not shipped | matches, verbatim | matches | values match; `nagai-twilight.nvim` matches somerocketeer/nagai-twilight.nvim `e5692be` | upstream names `placeholder`; 54 values in no upstream file | none |
| `nebulite` | `01fac1f` | diverges (1) | overlay (1 keys, 1 in no upstream file) | matches, verbatim | matches | diverges (7 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 55 values in no upstream file | none |
| `oxford` | `7025c18` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | values match; `gruvbox-material` matches sainnhe/gruvbox-material `11d779b` | no upstream file; 53 values in no upstream file | none |
| `pmndrs` | `b115d05` | matches | not shipped | matches, verbatim | not shipped | values match; `poimandres.nvim` matches olivercederborg/poimandres.nvim `a488957`; no licence file | no upstream file; 59 values in no upstream file | none |
| `reddcs` | `9dd5db2` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 55 values in no upstream file | `apps/claude-light.json`: no upstream file; 6 of 6 values in no upstream file |
| `reverie` | `b1e6e72` | matches | not shipped | matches, verbatim | not shipped | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 55 values in no upstream file | none |
| `roseofdune` | `d6dc57d` | diverges (1) | not shipped | matches, verbatim | matches | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | diverges (813) from `vscode-extension/themes/roseofdune-color-theme.json` | `apps/alacritty.toml` 7 slots differ, 6 values in no upstream file; `apps/kitty.conf` 7 slots differ, 11 values in no upstream file; `apps/ghostty.conf` 7 slots differ, 6 values in no upstream file; `apps/foot.ini` no upstream file, 6 values in no upstream file; `apps/wezterm.lua` no upstream file, 12 values in no upstream file |
| `saga` | `7af52aa` | matches | not shipped | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | diverges (724) from `vscode-extension/themes/saga-color-theme.json` | none |
| `sapphire` | `2084a56` | matches | not shipped | matches, verbatim | matches | values match; `nightfall.nvim` matches 2giosangmitom/nightfall.nvim `0382566` in every Lua file; 8 PNG files differ | upstream names `jzbakh.antigravity-arn-skin`; 62 values in no upstream file | none |
| `snow` | `6cb2bea` | matches | not shipped | matches, verbatim | matches | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 55 values in no upstream file | none |
| `soho` | `1419aa2` | matches | not shipped | matches, verbatim | not shipped | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | upstream names `mvllow.rose-pine`; 61 values in no upstream file | none |
| `thegreek` | `678f70c` | matches | overlay (3 keys, 2 in no upstream file) | matches, verbatim | matches | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | diverges (875) from `vscode-extension/themes/thegreek-color-theme.json` | none |
| `tycho` | `8f759e7` | matches | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | values match; `pixel.nvim` matches bjarneo/pixel.nvim `fd06541` | no upstream file; 50 values in no upstream file | none |
| `untitled` | `cb49a53` | matches | not shipped | matches, verbatim | matches | diverges (5 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | upstream names `VueComputedTheme.styldev`; 35 values in no upstream file | none |
| `vengeance` | `0738cca` | diverges (1) | overlay (2 keys, 2 in no upstream file) | matches, verbatim | matches | diverges (7 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 58 values in no upstream file | none |
| `vice-city` | `8c676d8` | diverges (1) | not shipped | matches, verbatim | matches | values match; `tokyonight.nvim` matches, 2 non-colour script files differ (VGS-318) | no upstream file; 74 values in no upstream file | `apps/claude-light.json`: no upstream file; 6 of 6 values in no upstream file |
| `void` | `c1fc95a` | matches | not shipped | matches, verbatim | matches | values match; `catppuccin` matches (VGS-318) | upstream names `nataliefruitema.modern-purple-theme`; 63 values in no upstream file | none |
| `vurple` | `fd4cb06` | diverges (1) | not shipped | matches, verbatim | matches | diverges (7 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 63 values in no upstream file | none |
| `x-1632` | `4537e9f` | matches | overlay (2 keys, 2 in no upstream file) | not shipped | not shipped | diverges (6 values in no upstream file); `aether.nvim` matches bjarneo/aether.nvim `02af9ba` | no upstream file; 61 values in no upstream file | none |

### D017's named departure classes

**VGS-286 `apps/claude-light.json`.** Departs in all six packages. None of the six upstream repositories ships a Claude Code file at the closest commit. The 36 values are VGS-picked diff colours:

- `akane`: `#4a9c45`, `#65c55f`, `#85bc81`, `#d3a39c`, `#e25d4e`, `#e7998d`.
- `archwave`: `#44913f`, `#5fb959`, `#7db079`, `#ce968d`, `#da5041`, `#e48a7d`.
- `frankenstein`: `#58b752`, `#77e570`, `#9cda96`, `#e2c4c0`, `#e78678`, `#efbfb7`.
- `moon-orbit`: `#61c85a`, `#9bf494`, `#b7ebb2`, `#eb9c90`, `#ebd9d6`, `#f4d6d0`.
- `reddcs`: `#438e3e`, `#5db557`, `#7aac76`, `#cc9289`, `#e38577`, `#f0bbb3`.
- `vice-city`: `#438e3e`, `#5db557`, `#7aac76`, `#cc9188`, `#d44d3f`, `#e38476`.

**VGS-290 terminal overlays.** Departs in all 18 packages that ship one: 17 from VGS-290 and `thegreek`'s from VGS-281. Only `thegreek`'s `color0` `#242424` appears in an upstream file, and there it belongs to a different slot.

| Package | Written by | Key: VGS value (upstream slot value) | In no upstream file |
|---|---|---|---|
| `akane` | VGS-290 | `color2` `#68985d` (`#be6f76`), `color10` `#4c963b` (`#c85670`) | 2 of 2 |
| `arc-raiders` | VGS-290 | `color1` `#7a555a` (`#6a5457`), `color2` `#357e22` (`#b0413b`), `color9` `#a78187` (`#9f8589`), `color10` `#79ac6e` (`#d4827d`) | 4 of 4 |
| `biscuit-de-mar` | VGS-290 | `color2` `#80a079` (`#959a6b`) | 1 of 1 |
| `cpunk` | VGS-290 | `color2` `#c8d7c5` (`#d1d2d1`), `color10` `#deedda` (`#ffffff`) | 2 of 2 |
| `ember-n-ash` | VGS-290 | `color2` `#7a9c72` (`#9e8f70`), `color10` `#8daa86` (`#b39c7c`) | 2 of 2 |
| `greek-noir` | VGS-290 | `color1` `#d9544b` (`#aeab94`), `color2` `#3dad1b` (`#f25623`), `color9` `#d9544b` (`#aeab94`), `color10` `#3dad1b` (`#f25623`) | 4 of 4 |
| `harbordark` | VGS-290 | `color2` `#4aa833` (`#e75a50`), `color10` `#6b8c63` (`#77838a`) | 2 of 2 |
| `kurayami` | VGS-290 | `color1` `#eeaea6` (`#d9bc87`), `color9` `#d6b5b0` (`#eedec3`) | 2 of 2 |
| `lowlight` | VGS-290 | `color1` `#a88282` (`#a48484`), `color2` `#7e9e76` (`#af8a79`), `color10` `#92ae8c` (`#be9c8e`) | 3 of 3 |
| `mechanoonna` | VGS-290 | `color2` `#86a67f` (`#a89984`), `color10` `#90b688` (`#c2a571`) | 2 of 2 |
| `moon-orbit` | VGS-290 | `color2` `#5a8151` (`#965f81`), `color10` `#8ba884` (`#bb90a1`) | 2 of 2 |
| `nebulite` | VGS-290 | `color10` `#8baa84` (`#b39898`) | 1 of 1 |
| `oxford` | VGS-290 | `color2` `#688a61` (`#76856a`), `color10` `#9fb899` (`#a8b49d`) | 2 of 2 |
| `reddcs` | VGS-290 | `color2` `#5c7b55` (`#806c61`), `color10` `#5c7b55` (`#806c61`) | 2 of 2 |
| `thegreek` | VGS-281 | `color0` `#242424` (`#d0d0c8`), `color7` `#a6a696` (`#383835`), `color15` `#a6a696` (`#242424`) | 2 of 3 |
| `tycho` | VGS-290 | `color2` `#6d9465` (`#b4756b`), `color10` `#afc5aa` (`#d6b4af`) | 2 of 2 |
| `vengeance` | VGS-290 | `color2` `#bcdab6` (`#eec8aa`), `color10` `#bfddb8` (`#eeccaa`) | 2 of 2 |
| `x-1632` | VGS-290 | `color2` `#73976b` (`#8b8e76`), `color10` `#87a580` (`#9b9e85`) | 2 of 2 |

**Horizon `apps/btop.theme`.** Outside the community imports. The facts are under Tradeoffs, because the rule is the owner's decision.

### Other departures

`apps/vscode-theme.json` compared with a theme file in the upstream repository, at the commit with the fewest differing keys:

| Package | Upstream file | Commit | Differing keys: `colors`, `semanticTokenColors`, `tokenColors` | Upstream counts: colors, tokenColors, semanticTokenColors |
|---|---|---|---|---|
| `akane` | `vscode-extension/themes/akane-color-theme.json` | [`8ab3d02`](https://github.com/Grenish/omarchy-akane-theme/tree/8ab3d0211f8627551fc9a7ecea5b578f9721639e) | 740: 585, 13, 142 | 208, 28, 15 |
| `frankenstein` | `vscode-extension/themes/aether-color-theme.json` | [`94f7995`](https://github.com/twodogsdave/omarchy-frankenstein-theme/tree/94f79954a5109d0a08aa97e0a0f425637d1a58db) | 199: 92, 22, 85 | 664, 81, 36 |
| `harbordark` | `vscode-extension/themes/harbordark-color-theme.json` | [`5203f4d`](https://github.com/HANCORE-linux/omarchy-harbordark-theme/tree/5203f4d4e4910a718925c4c3e996d794772a0531) | 536: 347, 36, 153 | 664, 81, 36 |
| `mechanoonna` | `vscode-extension/themes/mechanoonna-color-theme.json` | [`1e24144`](https://github.com/HANCORE-linux/omarchy-mechanoonna-theme/tree/1e241448ff6f91376769b0eb41c96141f2072f23) | 0: 0, 0, 0 | 664, 81, 36 |
| `roseofdune` | `vscode-extension/themes/roseofdune-color-theme.json` | [`d6dc57d`](https://github.com/HANCORE-linux/omarchy-roseofdune-theme/tree/d6dc57d6482fdd41fdc08dad9784cffaabaeb0cd) | 813: 630, 24, 159 | 89, 22, 0 |
| `saga` | `vscode-extension/themes/saga-color-theme.json` | [`7af52aa`](https://github.com/HANCORE-linux/omarchy-saga-theme/tree/7af52aae19d2dc7c3f27fa0981b57b8bba9313ea) | 724: 522, 31, 171 | 336, 20, 36 |
| `thegreek` | `vscode-extension/themes/thegreek-color-theme.json` | [`678f70c`](https://github.com/HANCORE-linux/omarchy-thegreek-theme/tree/678f70c07a433a0522ed5aba260bbe0a0b42eb5e) | 875: 568, 24, 283 | 449, 74, 0 |

The 43 VS Code files that share one key set carry 664 `colors` keys, the same set as Aether's VS Code template at bjarneo/aether [`5fb7839`](https://github.com/bjarneo/aether/tree/5fb7839be09e9a96514efbdc8a0a611cac673f80). Their 69 `tokenColors` entries and 24 `semanticTokenColors` keys match no version of that template: its history holds 81 and 36, 73 and 36, and 73 and 0. `arc-blueberry`'s file equals `extension/themes/bearded-theme-arc-blueberry.json` in [Open VSX BeardedBear.beardedtheme 10.1.0](https://open-vsx.org/extension/BeardedBear/beardedtheme/10.1.0) (SHA-256 `ecc92f2c469dce007b69fd3595889b10ea879fd6efce5a603131228900651330`) on every key.

`apps/neovim.lua` values in no upstream file, all in Aether specs. The upstream specs pass `base00` to `base0F`; the VGS specs pass a named palette whose keys carry these values:

| Package | Values in no upstream file | Keys carrying them |
|---|---|---|
| `arc-raiders` | 5 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `lighter_bg` |
| `artzen` | 7 | `accent`, `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `brutalism` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `cpunk` | 5 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `lighter_bg` |
| `event-horizon` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `fireside` | 5 | `brown`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `frankenstein` | 5 | `brown`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `ghost-pastel` | 5 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `lighter_bg` |
| `greek-noir` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `harbordark` | 5 | `brown`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `kurayami` | 5 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `lighter_bg` |
| `lowlight` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `moon-orbit` | 5 | `brown`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `nebulite` | 7 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg`, `selection`, `selection_background` |
| `reddcs` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `reverie` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `roseofdune` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `saga` | 5 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg` |
| `snow` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `soho` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `thegreek` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `untitled` | 5 | `brown`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `vengeance` | 7 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg`, `selection`, `selection_background` |
| `vurple` | 7 | `accent`, `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |
| `x-1632` | 6 | `brown`, `dark_bg`, `dark_fg`, `darker_bg`, `light_fg`, `lighter_bg` |

`colors.toml`:

- `amberbyte/colors.toml`: `selection_foreground` `#f2e8e8` (upstream `ghostty.conf` `#eaeaea`, `kitty.conf` `#121212`).
- `arc-blueberry/colors.toml`: `selection_background` `#373a4b` (in no upstream file).
- `archwave/colors.toml`: `selection_background` `#432e5c` (upstream `kitty.conf` `#2d1b4e`).
- `artzen/colors.toml`: `accent` `#ed333b` (in no upstream file).
- `lunar/colors.toml`: `accent` `#ffffff` (in no upstream file).
- `nebulite/colors.toml`: `selection_background` `#4c4c4f` (in no upstream file).
- `roseofdune/colors.toml`: `accent` `#9e4f5b` (upstream `#76634c`).
- `vengeance/colors.toml`: `selection_background` `#444242` (in no upstream file).
- `vice-city/colors.toml`: `selection_background` `#3e283f` (in no upstream file).
- `vurple/colors.toml`: `accent` `#450090` (in no upstream file).

`artzen`, `lunar` and `vurple` hold their accent upstream only inside an eight-digit Hyprland border value (`rgba(ed333bee)`, `rgba(ffffffaa)`, `rgba(450090ee)`). The comparison keeps eight-digit values whole, so these accents count as values in no upstream file.

Keys unverified by role: no upstream terminal file sets the slot, and the value appears in another upstream file. They count neither as matches nor as differences.

| Package | Keys unverified by role |
|---|---|
| `akane` | `accent` `#9279aa` |
| `amberbyte` | `accent` `#b44a4a` |
| `arc-blueberry` | `cursor` `#bcc1dc`, `selection_foreground` `#bcc1dc`, `accent` `#f38cec` |
| `arc-raiders` | `selection_foreground` `#0c060d`, `selection_background` `#fafafa`, `accent` `#0c060d` |
| `archwave` | `accent` `#ff6ec7` |
| `artzen` | `selection_foreground` `#181c1f`, `selection_background` `#fdf9f8` |
| `delorean` | `accent` `#ff2a6d` |
| `ember-n-ash` | `accent` `#ff6f3c` |
| `lowlight` | `selection_foreground` `#dcd7d6`, `selection_background` `#a39eb8`, `accent` `#cb8c6d` |
| `lunar` | `selection_foreground` `#181c1f`, `selection_background` `#e1e4e8` |
| `monokai` | `selection_foreground` `#0a1220`, `selection_background` `#f0f2f5`, `accent` `#aba0f2` |
| `nagai-twilight` | `accent` `#bd93f9` |
| `nebulite` | `selection_foreground` `#dcd6d6`, `accent` `#4c566a` |
| `tycho` | `accent` `#b4756b` |
| `vengeance` | `selection_foreground` `#faf9f9`, `accent` `#e46867` |
| `vice-city` | `selection_foreground` `#f793d9`, `accent` `#f793d9` |
| `vurple` | `selection_foreground` `#050111`, `selection_background` `#c9ffff` |

`roseofdune`'s five terminal files were hand-written by `86d34784` to make the theme readable in Claude Code's light ANSI mode. `apps/alacritty.toml`, `apps/kitty.conf` and `apps/ghostty.conf` each differ from the upstream file of the same name in 7 slots (`color0`, `color2`, `color6`, `color7`, `color8`, `color10`, `color15`). The upstream publishes no foot or WezTerm file.

### Vendored Neovim trees

Each tree was staged as a git tree in a clone of the plugin repository and compared with every commit. This table lists the trees VGS-318 did not compare; `matteblack.nvim`, `tokyonight.nvim`, `gruvbox.nvim`, `catppuccin` and `vim-synthwave84` are in VGS-318.

| Tree | Loaded by | Closest commit | Differences | Licence file |
|---|---|---|---|---|
| `aether.nvim` | 25 packages | [bjarneo/aether.nvim `02af9ba`](https://github.com/bjarneo/aether.nvim/tree/02af9ba1ef9d6f136a6b20404d39f2a4e3857e16) | none | `LICENSE` |
| `biscuit.nvim` | `biscuit-de-mar` | [Biscuit-Theme/nvim `1307d87`](https://github.com/Biscuit-Theme/nvim/tree/1307d875ac42c5bf620b311781de7211521a0e42) | none | none |
| `gruvbox-material` | `mechanoonna`, `oxford` | [sainnhe/gruvbox-material `11d779b`](https://github.com/sainnhe/gruvbox-material/tree/11d779b26a9ab2b3db8c22c6ac9fb6e8ed4fea79) | none | `LICENSE` |
| `lake-dweller.nvim` | `inkypinky` | [yonatanperel/lake-dweller.nvim `67e0048`](https://github.com/yonatanperel/lake-dweller.nvim/tree/67e0048ca1a27d62348b0a9e593223bfab63fac8) | none | `LICENSE` |
| `monokai-pro.nvim` | `monokai` | [loctvl842/monokai-pro.nvim `a68e38b`](https://github.com/loctvl842/monokai-pro.nvim/tree/a68e38b8e55d69a215d0f02598900a79c356da9d) | none | `LICENSE` |
| `nagai-twilight.nvim` | `nagai-twilight` | [somerocketeer/nagai-twilight.nvim `e5692be`](https://github.com/somerocketeer/nagai-twilight.nvim/tree/e5692be75c010acf55d5e193c99f88ccc4b80dce) | none | `LICENSE` |
| `nightfall.nvim` | `sapphire` | [2giosangmitom/nightfall.nvim `0382566`](https://github.com/2giosangmitom/nightfall.nvim/tree/0382566bab17dbae50e782bab9507d7c9563ff94) | 8 PNG files under `assets/` added; no Lua file differs | `LICENSE` |
| `pixel.nvim` | `tycho` | [bjarneo/pixel.nvim `fd06541`](https://github.com/bjarneo/pixel.nvim/tree/fd06541f7c790e22ad18f0ee5873b246de5b4a87) | none | `LICENSE` |
| `poimandres.nvim` | `pmndrs` | [olivercederborg/poimandres.nvim `a488957`](https://github.com/olivercederborg/poimandres.nvim/tree/a488957d803943a4201ac3b774913fcafa9e6b3a) | none | none |

### Upstream sources

"Closest commit" is the upstream commit with the fewest differences from the package, newest on a tie. It is not a recorded import commit: VGS history begins at `b9a4196d` (2026-07-26) and does not name one.

| Package | Repository | Closest commit | HEAD on 2026-09-14 | Commits | Licence file at HEAD |
|---|---|---|---|---|---|
| `akane` | Grenish/omarchy-akane-theme | [`8ab3d02`](https://github.com/Grenish/omarchy-akane-theme/tree/8ab3d0211f8627551fc9a7ecea5b578f9721639e) (2026-01-03) | [`bfe2285`](https://github.com/Grenish/omarchy-akane-theme/tree/bfe2285358552b4c2eb545db43c814a2ffe1b8df) (2026-08-31) | 35 | none |
| `amberbyte` | tahfizhabib/omarchy-amberbyte-theme | [`8ea68b3`](https://github.com/tahfizhabib/omarchy-amberbyte-theme/tree/8ea68b3471f9f67d5b10921f401737e99d53fb24) (2025-12-26) | same as pin | 16 | `LICENSE` (MIT) |
| `arc-blueberry` | vale-c/omarchy-arc-blueberry | [`3476e99`](https://github.com/vale-c/omarchy-arc-blueberry/tree/3476e9933fec6913dafc6102e08c39f6ba8f4598) (2026-05-16) | [`56c0679`](https://github.com/vale-c/omarchy-arc-blueberry/tree/56c0679f161ef7198ba089d070dd8cad0bad5b87) (2026-08-23) | 8 | `LICENSE` (MIT) |
| `arc-raiders` | rondilley/omarchy-arc_raiders-theme | [`f0cfc37`](https://github.com/rondilley/omarchy-arc_raiders-theme/tree/f0cfc37fe6e0f612646c056e2219a0d6ecd42d95) (2025-10-14) | same as pin | 2 | `LICENSE` (GPL-3.0) |
| `archwave` | davidguttman/archwave | [`b3e6b81`](https://github.com/davidguttman/archwave/tree/b3e6b814989dc5dd58b25bc4c73667b4827bcb4c) (2026-01-23) | same as pin | 15 | none |
| `artzen` | tahfizhabib/omarchy-artzen-theme | [`d425535`](https://github.com/tahfizhabib/omarchy-artzen-theme/tree/d4255350a0ca7acd3f681b5da49e46bd15f41b9a) (2025-11-12) | same as pin | 7 | none |
| `biscuit-de-mar` | OldJobobo/omarchy-biscuit-de-mar-dark-theme | [`bdec74a`](https://github.com/OldJobobo/omarchy-biscuit-de-mar-dark-theme/tree/bdec74a8ac5608b9d7de1160c8e480933a422aeb) (2026-08-13) | [`e87f5f2`](https://github.com/OldJobobo/omarchy-biscuit-de-mar-dark-theme/tree/e87f5f2eba826c2a2863ba038fd708a7a38a1016) (2026-08-13) | 16 | none |
| `brutalism` | bjornramberg/omarchy-brutalism-theme | [`21c9887`](https://github.com/bjornramberg/omarchy-brutalism-theme/tree/21c9887ce86e8357d3c8a90a9c1d1764294e0de7) (2026-02-15) | same as pin | 11 | `LICENSE` (GPL-3.0) |
| `coppernight` | hembramnishant50-glitch/omarchy-coppernight-theme | [`5a2380a`](https://github.com/hembramnishant50-glitch/omarchy-coppernight-theme/tree/5a2380ac6c985d0eac6032d518e5d82cd18fb077) (2026-08-09) | [`0a8106e`](https://github.com/hembramnishant50-glitch/omarchy-coppernight-theme/tree/0a8106e3f73058a08e78c4aabb2c58e514ca62b5) (2026-09-01) | 243 | none |
| `cpunk` | stannorbvb-cmd/cpunk | [`c4d726b`](https://github.com/stannorbvb-cmd/cpunk/tree/c4d726bea9e6e4b3feb477c052e25bfcb2832ea4) (2026-03-18) | same as pin | 33 | none |
| `delorean` | jbnunn/omarchy-delorean-theme | [`41de4ca`](https://github.com/jbnunn/omarchy-delorean-theme/tree/41de4ca1d4c9604bd435ee03d0f7d5ca9c264fda) (2025-10-01) | same as pin | 4 | `LICENSE` (MIT) |
| `ember-n-ash` | Hydradevx/omarchy-ember-n-ash-theme | [`dcb94c8`](https://github.com/Hydradevx/omarchy-ember-n-ash-theme/tree/dcb94c804dae1f5c9a01ccd76429505981cc0213) (2025-08-13) | same as pin | 14 | none |
| `event-horizon` | OldJobobo/omarchy-event-horizon-theme | [`d0f689b`](https://github.com/OldJobobo/omarchy-event-horizon-theme/tree/d0f689bef921ab35c496ef3285d397d5d5417f31) (2026-06-21) | [`3e306a8`](https://github.com/OldJobobo/omarchy-event-horizon-theme/tree/3e306a897442da05c147f32ac98cf9e7896294ae) (2026-08-12) | 38 | none |
| `fireside` | bjarneo/omarchy-fireside-theme | [`74b5633`](https://github.com/bjarneo/omarchy-fireside-theme/tree/74b5633bdc9cd338fa54e194474c0da11ec42832) (2026-05-21) | [`d392f4c`](https://github.com/bjarneo/omarchy-fireside-theme/tree/d392f4cb697501388bd896300b5575ce5a461e65) (2026-08-30) | 11 | none |
| `frankenstein` | twodogsdave/omarchy-frankenstein-theme | [`94f7995`](https://github.com/twodogsdave/omarchy-frankenstein-theme/tree/94f79954a5109d0a08aa97e0a0f425637d1a58db) (2026-04-08) | same as pin | 3 | `LICENSE` (MIT), `LICENSE.txt` (MIT) |
| `ghost-pastel` | row-huh/omarchy-ghost-pastel-theme | [`d8e1b55`](https://github.com/row-huh/omarchy-ghost-pastel-theme/tree/d8e1b554412737240c6d6ba19c652d64c433092b) (2026-07-27) | same as pin | 10 | none |
| `greek-noir` | HANCORE-linux/omarchy-greek-noir-theme | [`4dde93c`](https://github.com/HANCORE-linux/omarchy-greek-noir-theme/tree/4dde93cb42f775af791957d828ae8ff9728f7796) (2026-08-10) | same as pin | 37 | `LICENSE` (MIT) |
| `gruvy-glass` | signaldirective/gruvy-glass | [`1204ee7`](https://github.com/signaldirective/gruvy-glass/tree/1204ee73e0e81c1cad63817131d118ad4f0a663d) (2026-06-13) | same as pin | 5 | none |
| `harbordark` | HANCORE-linux/omarchy-harbordark-theme | [`5203f4d`](https://github.com/HANCORE-linux/omarchy-harbordark-theme/tree/5203f4d4e4910a718925c4c3e996d794772a0531) (2026-08-05) | same as pin | 122 | `LICENSE` (MIT) |
| `inkypinky` | HANCORE-linux/omarchy-inkypinky-theme | [`1e5e799`](https://github.com/HANCORE-linux/omarchy-inkypinky-theme/tree/1e5e79929ca061f904dd8fb6fbe127791d0036e6) (2026-08-05) | same as pin | 74 | `LICENSE` (MIT) |
| `kurayami` | bjornramberg/omarchy-kurayami-theme | [`96a3250`](https://github.com/bjornramberg/omarchy-kurayami-theme/tree/96a3250ef2210cf7bc4b078e13b0bb5f2c27b03a) (2026-02-10) | same as pin | 11 | `LICENSE` (GPL-3.0) |
| `lowlight` | atif-1402/omarchy-lowlight-theme | [`c685f81`](https://github.com/atif-1402/omarchy-lowlight-theme/tree/c685f8168299d8e1db3e17b2ba1ed9a505dd35f2) (2026-02-07) | [`8105514`](https://github.com/atif-1402/omarchy-lowlight-theme/tree/81055141f0c2b07a23507c5abbd5f82c62d2b8a8) (2026-03-05) | 11 | none |
| `lunar` | pdfosborne/omarchy-lunar-theme | [`a31285f`](https://github.com/pdfosborne/omarchy-lunar-theme/tree/a31285fd7828ef7fd05ea3447bcc557a204e175f) (2025-11-09) | same as pin | 7 | none |
| `mechanoonna` | HANCORE-linux/omarchy-mechanoonna-theme | [`9ec02da`](https://github.com/HANCORE-linux/omarchy-mechanoonna-theme/tree/9ec02da120c9dfc85f6a49e1def8442dfc3d5320) (2026-07-09) | [`1e24144`](https://github.com/HANCORE-linux/omarchy-mechanoonna-theme/tree/1e241448ff6f91376769b0eb41c96141f2072f23) (2026-08-23) | 91 | `LICENSE` (MIT) |
| `monokai` | bjarneo/omarchy-monokai-theme | [`7a947e1`](https://github.com/bjarneo/omarchy-monokai-theme/tree/7a947e1aaa0d9de4511fa117a415f9fa3401ffad) (2025-10-03) | [`619b66e`](https://github.com/bjarneo/omarchy-monokai-theme/tree/619b66e36f160b30bec5a421948316310aba32ab) (2026-08-30) | 7 | none |
| `moon-orbit` | JJDizz1L/moon-orbit | [`60c4d32`](https://github.com/JJDizz1L/moon-orbit/tree/60c4d322eeac75d5e28e62fceb6e73340a2390ad) (2026-08-17) | same as pin | 28 | `LICENSE` (MIT) |
| `nagai-twilight` | mwaltzer/omarchy-nagai-twilight-theme | [`b101d8a`](https://github.com/mwaltzer/omarchy-nagai-twilight-theme/tree/b101d8a51e0d39d95caee3213837bd4383f8bc1a) (2025-09-22) | same as pin | 16 | `LICENSE` (MIT) |
| `nebulite` | atif-1402/omarchy-nebulite-theme | [`01fac1f`](https://github.com/atif-1402/omarchy-nebulite-theme/tree/01fac1fe312fc6dca22850a944735532fc982662) (2026-02-15) | same as pin | 5 | none |
| `oxford` | HANCORE-linux/omarchy-oxford-theme | [`7025c18`](https://github.com/HANCORE-linux/omarchy-oxford-theme/tree/7025c182729002349744dc178894c3d9b36f3f23) (2026-08-06) | same as pin | 52 | `LICENSE` (MIT) |
| `pmndrs` | leweyse/omarchy-pmndrs-theme | [`b115d05`](https://github.com/leweyse/omarchy-pmndrs-theme/tree/b115d0508f83699824555f119cba6f0d6b5bd697) (2026-05-05) | [`2ca080e`](https://github.com/leweyse/omarchy-pmndrs-theme/tree/2ca080e615a3dd3fd60709eee7c45d4a2f917f5e) (2026-08-22) | 21 | `LICENSE` (MIT) |
| `reddcs` | mohamedredachakir/LINUX-OMARCHY-REDDCS | [`9dd5db2`](https://github.com/mohamedredachakir/LINUX-OMARCHY-REDDCS/tree/9dd5db28e003d12857bc3298e3ca71c0efa1873a) (2026-01-27) | same as pin | 7 | none |
| `reverie` | bjarneo/omarchy-reverie-theme | [`b1e6e72`](https://github.com/bjarneo/omarchy-reverie-theme/tree/b1e6e72f6e69e4e61696dbc13598724231b8a612) (2026-05-21) | [`188dbf5`](https://github.com/bjarneo/omarchy-reverie-theme/tree/188dbf54b5143a38b6ce960828de02b1c949a10d) (2026-08-30) | 12 | none |
| `roseofdune` | HANCORE-linux/omarchy-roseofdune-theme | [`d6dc57d`](https://github.com/HANCORE-linux/omarchy-roseofdune-theme/tree/d6dc57d6482fdd41fdc08dad9784cffaabaeb0cd) (2026-08-05) | same as pin | 59 | `LICENSE` (MIT) |
| `saga` | HANCORE-linux/omarchy-saga-theme | [`7af52aa`](https://github.com/HANCORE-linux/omarchy-saga-theme/tree/7af52aae19d2dc7c3f27fa0981b57b8bba9313ea) (2026-08-05) | same as pin | 87 | `LICENSE` (MIT) |
| `sapphire` | HANCORE-linux/omarchy-sapphire-theme | [`2084a56`](https://github.com/HANCORE-linux/omarchy-sapphire-theme/tree/2084a563d2ccba4f2a2763c50c80d6b8bdbf16ba) (2026-08-05) | same as pin | 93 | `LICENSE` (MIT) |
| `snow` | 28bby/Snow-Theme | [`6cb2bea`](https://github.com/28bby/Snow-Theme/tree/6cb2bea72eb84ee2a166301e5aecbfa1e12d1d52) (2026-01-15) | same as pin | 3 | none |
| `soho` | bjarneo/omarchy-soho-theme | [`1419aa2`](https://github.com/bjarneo/omarchy-soho-theme/tree/1419aa2807d56ce7561efcb9f6c4826a8e74f0f1) (2026-03-08) | [`05d7557`](https://github.com/bjarneo/omarchy-soho-theme/tree/05d7557dd4f1e42425722d43fb57786cec2e134d) (2026-08-30) | 3 | none |
| `thegreek` | HANCORE-linux/omarchy-thegreek-theme | [`678f70c`](https://github.com/HANCORE-linux/omarchy-thegreek-theme/tree/678f70c07a433a0522ed5aba260bbe0a0b42eb5e) (2026-08-05) | same as pin | 97 | `LICENSE` (MIT) |
| `tycho` | leonardobetti/omarchy-tycho | [`8f759e7`](https://github.com/leonardobetti/omarchy-tycho/tree/8f759e7b568b3917544c42c52b4960c28fac7107) (2026-03-10) | same as pin | 7 | `LICENSE` (MIT) |
| `untitled` | niraletter/omarchy-untitled-theme | [`cb49a53`](https://github.com/niraletter/omarchy-untitled-theme/tree/cb49a534e49d29d9c4978648b2087d1cce942459) (2026-03-26) | same as pin | 7 | `LICENSE` (MIT) |
| `vengeance` | Grey-007/vengeance | [`0738cca`](https://github.com/Grey-007/vengeance/tree/0738cca9d02db894928d51db25aa3b1ea63ed90a) (2025-12-14) | same as pin | 3 | none |
| `vice-city` | lavarinimoreira/omarchy-vice-city-theme | [`8c676d8`](https://github.com/lavarinimoreira/omarchy-vice-city-theme/tree/8c676d8242452c1360e0dcb73cdb24bff42768e8) (2025-09-11) | same as pin | 4 | none |
| `void` | vyrx-dev/omarchy-void-theme | [`c1fc95a`](https://github.com/vyrx-dev/omarchy-void-theme/tree/c1fc95a579bf5c5e1d3b9edd43b1df501b5bd5c9) (2026-04-15) | same as pin | 25 | `LICENSE` (MIT) |
| `vurple` | tahfizhabib/omarchy-vurple-theme | [`fd4cb06`](https://github.com/tahfizhabib/omarchy-vurple-theme/tree/fd4cb06d69f771cc1cae39688f1b096640a66202) (2025-11-12) | same as pin | 7 | none |
| `x-1632` | OldJobobo/omarchy-x-1632-theme | [`4537e9f`](https://github.com/OldJobobo/omarchy-x-1632-theme/tree/4537e9f8ccb46d11e9d618426258d666430e5d7c) (2026-06-21) | same as pin | 10 | none |

### Upstream changes after the closest commit

| Package | Commits after the closest commit | `colors.toml` against HEAD |
|---|---|---|
| `akane` | 2 | 22 keys differ |
| `arc-blueberry` | 2 | HEAD publishes no 21-key terminal file |
| `biscuit-de-mar` | 1 | 13 keys differ |
| `coppernight` | 28 | 1 key differs |
| `event-horizon` | 1 | 7 keys differ |
| `fireside` | 1 | HEAD publishes no 21-key terminal file |
| `lowlight` | 5 | 1 key differs |
| `mechanoonna` | 2 | 1 key differs |
| `monokai` | 1 | HEAD publishes no 21-key terminal file |
| `pmndrs` | 4 | HEAD publishes no 21-key terminal file |
| `reverie` | 1 | HEAD publishes no 21-key terminal file |
| `soho` | 1 | HEAD publishes no 21-key terminal file |

### Licence evidence

- 23 upstream repositories have no licence file at HEAD, and the attribution table says "no LICENSE file" for exactly these 23. Without a licence the author grants no right to redistribute. VGS ships a verbatim `btop.theme` from 22 of them (`x-1632` ships none) and `ember-n-ash`'s `neovim.lua` verbatim. VGS-318 filed the unlicensed `vim-synthwave84` tree at priority 2 on the same ground.
- The vendored `poimandres.nvim` and `biscuit.nvim` trees have no licence file upstream or in VGS. `config/vshell/nvim/colorschemes/ATTRIBUTION.md` has no row for `poimandres.nvim` and lists `biscuit.nvim` with "—".
- `arc-raiders`, `brutalism` and `kurayami` are GPL-3.0 ("Version 3, 29 June 2007" in each `LICENSE`). VGS is MIT and ships their `btop.theme` files verbatim. `arc-blueberry`'s VS Code file comes from Bearded Theme, whose 10.1.0 package carries a GPL-3.0 `extension/LICENSE.txt`. GPL-3.0 permits redistribution when the licence text travels with the files, and here it does not: `themes/` holds no LICENSE or COPYING file, and `themes/THEMES-ATTRIBUTION.md` gives only a URL and a licence name. The theme directories install to `/usr/lib/vshell/themes/*/` (`packaging/fedora/vgs-shell.spec`), and each package that installs them declares MIT only: `License: MIT` in `packaging/fedora/vgs-shell.spec`, `LICENSE="MIT"` in `packaging/gentoo/vgs-shell-0.5.0.ebuild`, and the single `Files: *` stanza with `License: MIT` in `packaging/debian/copyright`.
- The other 19 repositories carry an MIT `LICENSE`. The attribution table's licence column agrees with the repositories for all 45 packages.

### Scope boundary: the ten packages with no attribution row

Every package's history is the single VGS commit `b9a4196d` ("Initial commit"), so the upstream comes from the package files and `themes/BACKGROUNDS-ATTRIBUTION.md`. The comparison found the upstream `colors.toml` or terminal file with the fewest differing keys.

| Package | Upstream | Closest commit | `colors.toml` | Licence |
|---|---|---|---|---|
| `ethereal` | basecamp/omarchy `themes/ethereal` | [`d80c98f`](https://github.com/basecamp/omarchy/tree/d80c98f02546bb78638c57db55eaf7e19a69f13c) | matches | MIT |
| `hackerman` | basecamp/omarchy `themes/hackerman` | [`9c4ff68`](https://github.com/basecamp/omarchy/tree/9c4ff68a43b06aa5d99c9a08a3b5c5f2d7707d13) | matches | MIT |
| `last-horizon` | basecamp/omarchy `themes/last-horizon` | [`9c4ff68`](https://github.com/basecamp/omarchy/tree/9c4ff68a43b06aa5d99c9a08a3b5c5f2d7707d13) | matches | MIT |
| `lumon` | basecamp/omarchy `themes/lumon` | [`e757ae9`](https://github.com/basecamp/omarchy/tree/e757ae98ea4ed65f91a7fc6e0c0120885251ef4f) | matches | MIT |
| `retro-82` | basecamp/omarchy `themes/retro-82` | [`a68f2ae`](https://github.com/basecamp/omarchy/tree/a68f2ae04588ca808cbbb8951679a97208619e3b) | diverges (1): `background` | MIT |
| `solitude` | basecamp/omarchy `themes/solitude` | [`9c4ff68`](https://github.com/basecamp/omarchy/tree/9c4ff68a43b06aa5d99c9a08a3b5c5f2d7707d13) | matches | MIT |
| `vantablack` | basecamp/omarchy `themes/vantablack` | [`301ea3e`](https://github.com/basecamp/omarchy/tree/301ea3ecc652a19fbeae3e6178c8b2eec57fa646) | matches | MIT |
| `white` | basecamp/omarchy `themes/white` | [`d80c98f`](https://github.com/basecamp/omarchy/tree/d80c98f02546bb78638c57db55eaf7e19a69f13c) | matches | MIT |
| `bauhaus` | mwaltzer/omarchy-bauhaus-theme | [`bfcabfd`](https://github.com/mwaltzer/omarchy-bauhaus-theme/tree/bfcabfddb89dc56e95441b7a43919c662a468a14) | diverges (2): `cursor`, `selection_foreground`; `apps/btop.theme` and `apps/chromium.theme` match | MIT |
| `noctalia` | noctalia-dev/noctalia-shell, default scheme | [`79e74d6`](https://github.com/noctalia-dev/noctalia-shell/tree/79e74d67437ff9bb9d7df16f7c9599f5851305a0) (branch `legacy-v4`) | diverges (12) from `Noctalia-default-dark.conf`; the built-in `Noctalia` palette at [`5d66d11`](https://github.com/noctalia-dev/noctalia-shell/tree/5d66d118861fedcbe039d9d04d06904cced40613) also differs in 12 of 22 keys, and 11 VGS values appear nowhere in it | MIT |

basecamp/omarchy HEAD was [`b679363`](https://github.com/basecamp/omarchy/tree/b679363bed05415771a1b1dc92c6899a908236f7) on 2026-09-14. D017 applies to all ten packages, so each needs the app-file comparison this audit ran for the community imports; follow-up proposals 47 and 48 cover them.

## Tradeoffs / Alternatives

- **Owner decision: may a VGS-written app file stand when every colour in it is an upstream value?** D017 says that where the upstream publishes no file for an app, the package ships none and the generated render stands. Each Horizon `apps/btop.theme` sets 42 keys, and every value is a `colors.toml` value, which `test_horizon_packages_use_only_upstream_colours` also checks against the upstream globals. The generated render, `themes/targets/btop-vgs/vgs.theme`, reads only `{background}`, `{foreground}`, `{accent}` and `{colorN}` slots, so for Horizon it would also hold only upstream values. Rendered from each Horizon `colors.toml`, it differs from the hand-written file in 5 of 42 keys: `hi_fg`, `meter_bg`, `proc_box`, `selected_bg` and `selected_fg` in `horizon`, and `graph_text`, `main_fg`, `proc_misc`, `selected_fg` and `title` in `horizon-light`.
  - **If yes**, D017 gains a bullet that permits such a file and names the check that proves every value upstream. The Horizon files stay. The role mapping in those 5 keys stays a VGS judgement, which D017's first bullet otherwise gives to the upstream.
  - **If no**, both Horizon `apps/btop.theme` files are removed and D017 is unchanged. btop keeps the same upstream value set under the template's mapping.
  - **Community imports:** neither answer changes this audit's follow-ups. Every VGS-written file measured here holds at least one value in no upstream file, so none is in this class. The fewest is one, in the `biscuit-de-mar` and `nebulite` overlays.
- **Closest commit or HEAD.** 12 upstreams changed after the closest commit. Taking HEAD as the upstream changes `akane` in 22 `colors.toml` keys and `biscuit-de-mar` in 13, and six upstreams no longer publish a 21-key terminal file at HEAD. The follow-ups name the closest commit, because that is the theme users have now; HEAD would be a re-port.
- **Named extensions.** In 14 packages the upstream's `vscode.json` names a Marketplace extension or a placeholder. Most name a different theme; for example `amberbyte` names Matte Black and `soho` names Rosé Pine Moon. VGS-318 treated that case as no upstream file. The follow-ups do the same and offer the named extension's file only if the owner accepts it as the theme's own.
- **Reconciliation instead of removal.** D017 allows a VGS-owned reconciliation that `docs/architecture/theme.md` names. The owner could name the diff-hue overlays and the Claude light diff tokens as reconciliations instead of removing them. The follow-ups remove them by default, because D017's Current state section lists them as departures pending this audit.

## Recommendation / Decision Criteria

- Add no community-import rows yet. Each package gets its row once its follow-up leaves only upstream values.
- File the 48 proposals in `tmp/audit-issues-VGS-329.json`. Each per-package proposal takes its values from the closest commit this report names.
- Treat proposal 46, the licence proposal, first. It covers the files with no licence grant, the four GPL-3.0 files shipped without their licence text, and the MIT-only packaging declarations.
- The owner answers the Horizon `apps/btop.theme` question above before anyone edits D017 or the Horizon packages.

### Follow-up proposals

`tmp/audit-issues-VGS-329.json` carries each proposal with its requirements, reach, labels and priority.

1. `akane`: bring `terminal-colors.toml`, `apps/vscode-theme.json`, `apps/claude-light.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
2. `amberbyte`: bring `colors.toml`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
3. `arc-blueberry`: bring `colors.toml` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
4. `arc-raiders`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
5. `archwave`: bring `colors.toml`, `apps/vscode-theme.json`, `apps/claude-light.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
6. `artzen`: bring `colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
7. `biscuit-de-mar`: bring `terminal-colors.toml`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
8. `brutalism`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
9. `coppernight`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
10. `cpunk`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
11. `delorean`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
12. `ember-n-ash`: bring `terminal-colors.toml`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
13. `event-horizon`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
14. `fireside`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
15. `frankenstein`: bring `apps/neovim.lua`, `apps/vscode-theme.json`, `apps/claude-light.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
16. `ghost-pastel`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
17. `greek-noir`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
18. `gruvy-glass`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
19. `harbordark`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
20. `inkypinky`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
21. `kurayami`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
22. `lowlight`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
23. `lunar`: bring `colors.toml`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
24. `mechanoonna`: bring `terminal-colors.toml` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
25. `monokai`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
26. `moon-orbit`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json`, `apps/claude-light.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
27. `nagai-twilight`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
28. `nebulite`: bring `colors.toml`, `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
29. `oxford`: bring `terminal-colors.toml`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
30. `pmndrs`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
31. `reddcs`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json`, `apps/claude-light.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
32. `reverie`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
33. `roseofdune`: bring `colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json`, `apps/alacritty.toml`, `apps/kitty.conf`, `apps/ghostty.conf`, `apps/foot.ini`, `apps/wezterm.lua` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
34. `saga`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
35. `sapphire`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
36. `snow`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
37. `soho`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
38. `thegreek`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
39. `tycho`: bring `terminal-colors.toml`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
40. `untitled`: bring `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
41. `vengeance`: bring `colors.toml`, `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
42. `vice-city`: bring `colors.toml`, `apps/vscode-theme.json`, `apps/claude-light.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
43. `void`: bring `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
44. `vurple`: bring `colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
45. `x-1632`: bring `terminal-colors.toml`, `apps/neovim.lua`, `apps/vscode-theme.json` to upstream values. Priority 3; labels `agent:generalist`, `bug`.
46. Community themes ship third-party files without a licence grant or their GPL-3.0 text. Priority 2; labels `agent:generalist`, `security`, `owner-gated`.
47. noctalia: hold only Noctalia's published palette under D017. Priority 3; labels `agent:generalist`, `bug`.
48. Audit the nine unattributed upstream ports' app files under D017. Priority 3; labels `agent:researcher`, `research`.

## Risks / Unknowns

- The closest commit is inferred, not recorded. A package whose values held unchanged across several upstream commits pins the newest of them.
- A `colors.toml` key that no upstream terminal file sets cannot be checked by role. The 17 packages in the unverified-by-role table hold such keys, and a follow-up must confirm each role from the upstream's own usage.
- VS Code files were compared key by key only against theme files inside the upstream repository and against Bearded Theme 10.1.0. No other Marketplace extension was downloaded.
- The upstream clones omit blobs over 300 KB, and the reads do not fetch them. Images and videos were not read.
- Colour extraction reads `#rrggbb` and `#rrggbbaa`, bare hex after `=`, whitespace or `(`, and `r,g,b` triples. Named colours are not read. Eight-digit values are kept whole, so an upstream `#rrggbbaa` never matches a six-digit value.
- The VGS-328 shortfall counts come from its branch at `bf0dcc9e`, which is In Review and may change before it merges.

## Revisit Conditions

- An upstream publishes a new commit that changes a file this report compares.
- The owner answers the Horizon `apps/btop.theme` question, or names an overlay or Claude file as a VGS-owned reconciliation.
- A checker covers every package D017 applies to.

## Research Metadata

- Mode: local repository comparison. No Exa research ran, so there is no provider sidecar. Open VSX answered eight extension lookups and supplied one package.
- Clones, made on 2026-09-14 under the worktree's ignored `tmp/`: each community-import repository with `git clone --filter=blob:limit=300k --no-checkout`, and basecamp/omarchy, mwaltzer/omarchy-bauhaus-theme, noctalia-dev/noctalia-shell and bjarneo/aether the same way. Each Neovim plugin repository in the trees table was cloned with `--filter=blob:none`. Reads set `GIT_NO_LAZY_FETCH=1`.
- Closest commit: every commit reachable from the upstream HEAD is scored against the package. The score is the `colors.toml` key differences, plus `apps/btop.theme` key differences, plus 1 for a differing `apps/chromium.theme`, plus the `apps/neovim.lua` values found in no upstream text file at that commit. The lowest score wins, newest on a tie.
- `colors.toml`: the 21 terminal keys are compared with each upstream terminal file at the commit (`colors.toml`, `alacritty.toml` `[colors.*]`, `kitty.conf`, `ghostty.conf` `palette`), lowercased, and the file with the fewest differences is the reference. A key the reference does not set is compared with every other upstream terminal file that sets that slot, and counts as a difference when none holds the same value. Where no upstream terminal file sets the slot, the key counts as a difference when its value appears in no upstream text file, and is reported as unverified by role otherwise. `accent` compares with the upstream `colors.toml` `accent` where one exists; otherwise the no-slot rule applies.
- `terminal-colors.toml`: each key is reported with the reference file's value for that slot and with membership in the upstream colour set.
- `apps/btop.theme`: every `theme[key]="value"` pair compares with the upstream `btop.theme`. `apps/chromium.theme`: the `r,g,b` text compares with the upstream file, whitespace removed.
- Membership and matches: for every file class, membership in the set of colours from every upstream text file at the commit only ever establishes a departure (a value in no upstream file), never a match. Values compare whole: an eight-digit value matches only the same eight digits. `apps/neovim.lua` is reported as values match only by role: the file holds no colour value and loads a vendored tree the trees table compares, or every line carrying a colour, an `fg`/`bg`/`sp` assignment or a highlight link equals a line of the upstream `neovim.lua` or of the upstream colorscheme file the package inlines, whitespace and trailing commas removed. Measured this round for the 20 values-match rows: 12 hold no colour value and load a compared tree (`amberbyte`, `delorean`, `gruvy-glass`, `inkypinky`, `mechanoonna`, `monokai`, `nagai-twilight`, `oxford`, `sapphire`, `tycho`, `vice-city`, `void`; `delorean`'s 4 colour-scheme lines equal the upstream `neovim.lua`). In `archwave`, `biscuit-de-mar`, `coppernight`, `ember-n-ash` and `pmndrs`, every colour line (45, 67, 59, 58 and 17) equals a line of the upstream `neovim.lua`. `akane` and `lunar` keep all 163 and 183 colour lines of the upstream `colors/akane.lua` and `lunar.nvim/colors/lunar.vim`, and add none. `arc-blueberry` keeps all 18 colour lines of the upstream `neovim.lua`, written through a local `set` alias for `vim.api.nvim_set_hl`, and adds 7 lines that link Treesitter groups to existing groups or reuse the upstream `colors.fg`, plus `hi clear`; it introduces no colour.
- `apps/vscode-theme.json`: both files parse as JSON with comments and trailing commas removed. The count is `colors` keys, `semanticTokenColors` keys and (scope, setting) pairs of `tokenColors` that change or exist on one side only, values lowercased. Upstream candidates are `*-color-theme.json`, `themes/*.json` and a `vscode.json` that holds `colors`, at every commit; the report names the commit with the fewest differences.
- Vendored trees: in the plugin clone, `GIT_INDEX_FILE=<tmp> git --work-tree=config/vshell/nvim/colorschemes/<dir> add -A -f .` and `git write-tree` stage the tree, then `git diff-tree -r --no-renames --name-status <commit> <tree>` runs for every commit. The report names the commit with the fewest `M` plus `A` rows.
- Horizon: `themes/targets/btop-vgs/vgs.theme` is rendered by substituting each `{key}` with the package's `colors.toml` value, then compared pair by pair with `apps/btop.theme`.
- VGS-328: `contrastShortfalls` read from `themes/<name>/theme.json` in the `vgs-328` worktree at `bf0dcc9e`.
