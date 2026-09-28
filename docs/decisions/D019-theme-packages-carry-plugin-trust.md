# D019: Theme packages are directories with plugin trust; terminal slots are package files

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active (trust clause → D031)

**Research**: VGS-457

**Context**: A theme must restyle the shell and later application targets from one directory. The shell document is already a judged token override, but application target files may be curated package files that an application includes directly.

**Decision**: A theme package is a directory whose name equals its `theme.json` document name. `theme.json` is the shell document. `terminal.json` is an optional package file holding sixteen ANSI slots, not token table data. Curated application target files are package files and are written verbatim by later apply steps. Applying a third-party package is equal in privilege to enabling a plugin under [D010](D010-facade-scope-not-sandbox.md), because the shell process and user privileges are shared. [D031](D031-installed-themes-render-code-targets.md) supersedes this trust clause: an installed package's curated file is dropped on a target whose files run code. [D007](D007-install-runs-no-plugin-code.md) covers plugin install, which runs no plugin code; it does not cover theme apply. The package named `vgs` is reserved for the shipped defaults.

**Rationale**:

- One directory gives authors one unit to ship and gives the runner one unit to judge.
- Terminal slots are application input, not values the shell draws, so putting them in the token table would mix layers.
- A curated target file reaches another application's include path verbatim. That is the same trust class as enabling plugin code under the user's session, not a safe data-only override.
- Reserving `vgs` keeps the revert package stable when installed packages shadow shipped names.

**Revisit When**: Package signatures or a marketplace changes the trust model, or target renderers need a separate package schema.

**Verification**: `scripts/test-theme-logic.js` covers package acceptance and refusal rules; `bin/vgsh-theme-judge packages themes` validates shipped packages in `scripts/validate`.

**References**: [D007](D007-install-runs-no-plugin-code.md), [D010](D010-facade-scope-not-sandbox.md), [D015](D015-tokens-are-a-judged-table.md), [D031](D031-installed-themes-render-code-targets.md)
