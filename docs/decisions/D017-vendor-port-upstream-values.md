# D017: A theme ported from an upstream takes every colour value from that upstream's published files

[← Decision Index](INDEX.md)

**Date**: 2026-09-13 **Status**: Active **Research**: [VGS-318 vendor-port audit](../research/VGS-318-vendor-port-audit.md)

**Applies to**: every theme package in `themes/` that ports a theme with an official upstream implementation: a vendor's own theme repository, or the community theme repository a port was imported from.

**Context**: A curated package can carry a palette (`colors.toml`), terminal slots (`terminal-colors.toml`), declared UI roles (`ui-roles.toml`) and curated app files under `apps/`. No rule said where their values come from. A Horizon port rendered its VS Code file from the generated template and derived tones for the tmux status bar and borders that Horizon never published, and the owner compared VS Code, tmux and the shell against the upstream Horizon palette and found them wrong.

**Decision**: For a theme with an official upstream implementation, `colors.toml`, `terminal-colors.toml`, `ui-roles.toml` and every curated app file hold only values the upstream publishes, except through the permitted forms below. The rule governs colour values: a setting that names no colour, such as the icon theme name in `apps/icons.theme`, is outside it.

- Each value maps to a role the way the upstream itself uses it. Where the upstream publishes a VS Code theme, that file decides which tone each surface, border and status element takes.
- Formatting is free: key order, indentation, pretty-printing and the file's top-level theme name may change. Values may not.
- Four forms of VGS-owned difference are permitted. Outside them, a value the upstream publishes stays the upstream's, and a value it publishes nowhere is not invented. **Current state** below names every instance; a difference not named there is not permitted, whatever form it resembles.
  - A reconciliation. The VS Code terminal-slot overwrite, `augment_vscode_colors` in `bin/vshell_helper.py`, is the one in place.
  - A VGS value for a key or role the upstream sets no usable value for. `synthwave84`'s `accent`, `background` and `selection_background` are these: the upstream publishes no terminal background, its terminal selection background carries an alpha channel that `colors.toml` may not hold, and the accent answers to no terminal key at all.
  - A VGS value in a package's `terminal-colors.toml`, whose hex appears in no upstream file. This file paints a terminal only; `colors.toml` still hands the upstream value to the shell's derived roles, to pi and to every app template, so the upstream palette reaches every other consumer intact. `synthwave84`'s `color10` is the one permitted so far.
  - A curated app file for an app the upstream publishes no file for, where it improves the theme on that app. A community mapping is preferred over a generated render, with the keys it omits filled by VGS. Such a file is not removed once written.
- Where the upstream publishes a file for an app, the package uses that file. A hand-written or community substitute in its place would hold values the upstream contradicts.
- Where no upstream value meets a lint floor, the package keeps the closest upstream value and names the shortfall in `theme.json` under `contrastShortfalls`, which `vshell theme lint` reports as known. A lint floor is never a reason to substitute a hex the upstream did not publish; the four permitted forms above are the only routes to a VGS value. `themes/thegreek/theme.json` shows the form.
- `themes/THEMES-ATTRIBUTION.md` names, for each package built under this decision, the upstream palette file and the app files it was built from.

**Current state**: `horizon`, `horizon-light` and `synthwave84` are the packages built and attributed under this decision so far. The VGS-318 audit covers the vendor ports; the community imports listed in `themes/THEMES-ATTRIBUTION.md` are not yet audited.

These are permitted by the forms above and are not pending:

- `synthwave84`'s `terminal-colors.toml` slot, under the third form.
- Each Horizon package's `apps/btop.theme`, hand-mapped for an app Horizon publishes no file for, under the fourth form.
- The `apps/claude-light.json` files VGS-286 added to akane, archwave, frankenstein, moon-orbit, reddcs and vice-city, under the fourth form: no upstream publishes a Claude Code theme.
- `synthwave84`'s `apps/neovim.lua` and the tree it names, `config/vshell/nvim/colorschemes/vim-synthwave84`, under the fourth form: the upstream is a VS Code extension and publishes no Neovim file. The owner ruled licence arguments moot for theme values, so the tree stays as a VGS-held Neovim theme.
- The `apps/vscode-theme.json` that `tokyo-night-moon` and `osaka-jade` ship, and the `apps/neovim.lua` that `osaka-jade` ships, under the fourth form: neither vendor publishes a file for that app. These were the only departures the audit recorded for those two packages.

These departures on main are pending, not permitted by this decision:

- The twelve vendor ports whose `colors.toml` the VGS-318 audit lists as diverging, `synthwave84` now excluded.
- Any package's `terminal-colors.toml` holding a value this decision has not named as permitted, dark or light: the VGS-290 diff hues, such as `color2` in `themes/akane/terminal-colors.toml`, and the VGS-289 overlays in `catppuccin-latte`, `flexoki-light` and `rose-pine`. `rose-pine` and `kanagawa-dragon` reach this list by their overlay alone; their `colors.toml` already matches. Each becomes permitted when its package's `colors.toml` is aligned and **Current state** names the slot.
- A community Neovim port loaded where the vendor publishes an official Vim colorscheme: `dracula`, `nord`, `gruvbox`, `everforest`, `ayu` and `miasma`. The fourth form does not reach these; the vendor publishes a file for that app.
- `ristretto`'s VS Code file, whose licence forbids redistribution. That is this decision's own Revisit When condition and is owner-gated.

**Rationale**:

- A user who picks a vendor's theme expects the vendor's colours. A derived or contrast-adjusted tone is a colour the vendor never published, and the result reads as a different theme.
- The upstream's VS Code theme already records which tone each part of an interface takes. Mapping from it replaces a VGS judgement with the vendor's own.
- A named shortfall keeps lint truthful without changing the colour. The `contrastShortfalls` list already exists for this, so the rule needs no new mechanism.

**Alternatives Considered**:

| Alternative | Why rejected |
|---|---|
| Adjust a tone until it meets the lint floor | The owner kept thegreek's upstream accent at 2.17:1 against a darkened replacement. A floor warning on a port is not a reason to change its colour. |
| Render every app file from the generated template | That is how the Horizon port came out wrong in VS Code, tmux and the shell. |

**Revisit When**: an upstream value is unreadable in a way a named shortfall cannot answer, such as body text on its own background; an upstream licence forbids redistributing its files; or a checker covers every package this decision applies to.

**Verification**: No checker covers every such package. In `scripts/check-vshell-helper.py`, `test_horizon_packages_use_only_upstream_colours` checks the Horizon packages against the upstream globals, and `test_aligned_vendor_ports_take_the_upstream_terminal_palette` checks each package named in `UPSTREAM_TERMINAL_PACKAGES`. It pins the upstream VS Code file the package ships to a recorded digest, holds every upstream-sourced `colors.toml` key to the workbench key it comes from, and holds `terminal-colors.toml` to the slots the third form permits, reporting a permitted slot that holds a colour the upstream does publish. A slot or key outside those reddens until **Current state** names it. An `extra_keys` entry naming a key the upstream's terminal palette already answers is refused, so that table cannot reroute a slot to a surface the vendor never painted it from. The second form's instances are held by this record alone: no check can compare a VGS value against an upstream that publishes none, so `synthwave84`'s `accent`, `background` and `selection_background` are named here and checked nowhere. No checker covers the fourth form. `test_lint_reports_listed_shortfalls_as_known` checks the shortfall list.

**References**: `themes/THEMES-ATTRIBUTION.md`, `docs/architecture/theme.md`.

## Revisit Outcome (2026-09-15)

The VGS-318 audit compared all 24 vendor ports with their upstreams and found 18 departing. The owner re-assessed this decision against that result and kept it, with one refinement: a file or value the vendor never publishes may be written by VGS where it improves the theme, and is not removed once written. A value the vendor does publish stays the vendor's unless the owner asks for a change. Community app mappings are preferred over generated renders, with missing keys filled by VGS. Contrast checks stay lightweight; AA ratios are not a goal. The owner also ruled licence arguments moot for theme values, so `config/vshell/nvim/colorschemes/vim-synthwave84` and `themes/synthwave84/apps/neovim.lua` stay as a VGS-held Neovim theme.

The **Decision** section above records the value half of that refinement as the second and third permitted forms, and the file half as the fourth. **Current state** lists what each form now permits. `synthwave84` is the first package aligned under the refined decision.
