# D017: A theme ported from an upstream takes every colour value from that upstream's published files

[← Decision Index](INDEX.md)

**Date**: 2026-09-13 **Status**: Active **Research**: —

**Applies to**: every theme package in `themes/` that ports a theme with an official upstream implementation: a vendor's own theme repository, or the community theme repository a port was imported from.

**Context**: A curated package can carry a palette (`colors.toml`), terminal slots (`terminal-colors.toml`), declared UI roles (`ui-roles.toml`) and curated app files under `apps/`. No rule said where their values come from. A Horizon port rendered its VS Code file from the generated template and derived tones for the tmux status bar and borders that Horizon never published, and the owner compared VS Code, tmux and the shell against the upstream Horizon palette and found them wrong.

**Decision**: For a theme with an official upstream implementation, `colors.toml`, `terminal-colors.toml`, `ui-roles.toml` and every curated app file hold only values the upstream publishes.

- Each value maps to a role the way the upstream itself uses it. Where the upstream publishes a VS Code theme, that file decides which tone each surface, border and status element takes.
- Formatting is free: key order, indentation, pretty-printing and the file's top-level theme name may change. Values may not.
- A VGS-owned reconciliation is the only permitted difference, and `docs/architecture/theme.md` names each one. The VS Code terminal-slot overwrite, `augment_vscode_colors` in `bin/vshell-helper`, is one.
- Where the upstream publishes no file for an app, the package ships none and the generated render stands. A hand-written file there would hold invented values.
- Where no upstream value meets a lint floor, the package keeps the closest upstream value and names the shortfall in `theme.json` under `contrastShortfalls`, which `vshell theme lint` reports as known. VGS never substitutes a hex the upstream did not publish. `themes/thegreek/theme.json` shows the form.
- `themes/THEMES-ATTRIBUTION.md` names, for each such package, the upstream palette file and the app files it was built from.

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

**Verification**: No checker covers every such package. `test_horizon_packages_use_only_upstream_colours` in `scripts/check-vshell-helper.py` checks the Horizon packages, and `test_lint_reports_listed_shortfalls_as_known` checks the shortfall list.

**References**: `themes/THEMES-ATTRIBUTION.md`, `docs/architecture/theme.md`.
