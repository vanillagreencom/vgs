# Theme changes

Read [../docs/architecture/theme.md](../docs/architecture/theme.md) for palette, overlay and output-path contracts.

Per-theme app files intentionally share structure. Keep each package independently usable instead of extracting shared theme content.

A slot whose terminal meaning needs a different colour than the shell's derived roles and pi read goes in the package's `terminal-colors.toml`, never in `colors.toml`.
