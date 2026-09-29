# Built-in theme provenance (Omarchy community imports)

VGS catalog theme packages listed below were ported from community Omarchy theme repositories. Palettes and terminal colours are taken from the source. The v2 catalog does not ship v1 curated application files. Wallpapers stay in the pinned release archives, and the shipped thumbnails come from those sources (see BACKGROUNDS-ATTRIBUTION.md).

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

`moon-orbit` is listed for provenance, but the v2 catalog holds it back because its body text misses the readability floor. `synthwave84` is the one exception to the palette sentence above: its palette and terminal colours come from the upstream extension, not from the Omarchy source.

## Vendor ports

The v1 decision that governed these vendor ports is [D017 vendor port upstream values](https://github.com/vanillagreencom/vgs/blob/v1/docs/decisions/D017-vendor-port-upstream-values.md). The v2 catalog carries only shell palette values and terminal colours from these sources. The v1 branch keeps the application files and their checks.

| VGS theme | Palette and terminal source | License |
|---|---|---|
| `horizon` | [jolaleye/horizon-theme-vscode, dark globals](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/src/dark/globals.json) | [MIT, © 2018 Jonathan Olaleye](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/LICENSE) |
| `horizon-light` | [jolaleye/horizon-theme-vscode, bright globals](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/src/bright/globals.json) | [MIT, © 2018 Jonathan Olaleye](https://github.com/jolaleye/horizon-theme-vscode/blob/v2.0.2/LICENSE) |
| `synthwave84` | [RobbOwen.synthwave-vscode 0.1.20](https://open-vsx.org/extension/RobbOwen/synthwave-vscode/0.1.20), its `terminal.*` and `terminalCursor.foreground` keys plus the surfaces named below | MIT, © Robb Owen |

For the two Horizon packages, v2 uses the matching globals file for palette and terminal colours. The v1 branch carries the copied application files from the same MIT source at v2.0.2.

For `synthwave84`, twenty colour keys come from the extension. It sets twelve `terminal.ansi*` keys, and those answer `color1` to `color6` and `color9` to `color14`; `foreground` and `cursor` come from `terminal.foreground` and `terminalCursor.foreground`. It sets no black or white ANSI pair and no terminal key for the accent, so the remaining keys take the surfaces it paints them from: `accent` from `activityBarBadge.background`, `color0` from `editor.background`, `color8` from `button.background`, and `color7` and `color15` from the top-level `foreground`. The package's own values are `background`, which the extension answers nowhere, and `selection_background`, whose only upstream value carries an alpha channel.
