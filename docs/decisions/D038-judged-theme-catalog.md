# D038: First-party themes are a judged catalog in the vgs repository

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: VGS-539, [docs/plans/v2-platform-roadmap.md § Decisions](../plans/v2-platform-roadmap.md#decisions)

**Context**: VGS offers more themes than the two it ships: v1 catalogued 81, with wallpapers in per-theme release archives on `vanillagreencom/vgs-themes` (release `themes-v1`, pinned by size and sha256). v2 installs a theme only from a git URL (`vgsh theme add`). The theme-browser research weighed four sources for catalog definitions:

- **A.** Definitions in the vgs repository, `themes/catalog/<name>/` with one index, judged offline like `themes/*`.
- **B.** Definition archives on `vgs-themes`, pinned in the index; that repository holds releases and no code, so definitions would still be authored elsewhere, and install would need network.
- **C.** One git repository per theme, installed through `vgsh theme add`: 81 repositories, and wallpapers inside git cannot be skipped.
- **D.** All 81 as shipped packages: install on demand is gone, the list grows to 83 rows, and shipped trust gives every one curated code files ([D031](D031-installed-themes-render-code-targets.md)).

Omarchy lists only installed themes in its picker (`omarchy-theme-switcher` walks the shipped and user theme directories) and points to omarchy.org/themes for more, which `omarchy-theme-install` then clones from a git URL the user pastes.

**Decision**: Option A. First-party themes live in `themes/catalog/`: one `index.json` of `{ name, mode, thumbnail, palette, imagery }` entries, `imagery` null or `{ repo, release, archive, size, sha256 }`, and one package directory per entry. `ThemeLogic.acceptCatalogIndex` judges the index, `ThemeLogic.acceptCatalogEntry` judges each package as the installed package it becomes, and `bin/vgsh-theme-judge catalog-check themes` runs both in offline validation. A catalog package installs as an ordinary installed package; the catalog carries no curated file on a `runsCode` target, so no trust tier changes. Wallpapers stay in the pinned `vgs-themes` archives and download on demand on a lane of their own, apart from the theme runner's queue. Unlike Omarchy, the browser lists the judged catalog beside the installed packages.

**Rationale**:

- A catalog package needs no network to install, and every definition change reviews as a diff that the package judge has passed.
- Refusing curated code files in the catalog answers the trust question without touching [D019](D019-theme-packages-carry-plugin-trust.md) or D031: an installed catalog package loses nothing at apply, and no first-party exception exists for a later reader to widen.
- The `themes-v1` archives already hold `backgrounds/*`, v2's package shape, so the index pins them unchanged.
- A download of tens of megabytes on the theme runner's one queue would hold every list and apply behind it.
- Omarchy's picker lists nothing a user has not installed. A catalog the browser lists makes a theme one keystroke away, and the index's palette draws a card before any wallpaper exists.

**Revisit When**: The catalog grows past what the repository should carry, or catalog packages need code-carrying files with no template equivalent.

**Verification**: `scripts/test-theme-logic.js` covers every index rule and the entry judge, with a control per rule; `scripts/test-vgsh-theme-judge.js` covers `catalog-check`'s curated-file, symlink and thumbnail rules, with a control per rule; `scripts/validate` runs `bin/vgsh-theme-judge catalog-check themes` for `themes/catalog/*` changes.

**References**: [D019](D019-theme-packages-carry-plugin-trust.md), [D031](D031-installed-themes-render-code-targets.md)
