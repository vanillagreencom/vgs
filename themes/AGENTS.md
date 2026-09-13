# Theme changes

Read [../docs/architecture/theme.md](../docs/architecture/theme.md) for palette, overlay and output-path contracts. Read [../docs/architecture/agent-cli-themes.md](../docs/architecture/agent-cli-themes.md) for the agent CLI targets and the curated Claude Code files.

Per-theme app files intentionally share structure. Keep each package independently usable instead of extracting shared theme content.

A slot whose terminal meaning needs a different colour than the shell's derived roles and pi read goes in the package's `terminal-colors.toml`, never in `colors.toml`.

A curated package that publishes its own tone for a derived UI role states it in the package's `ui-roles.toml`. `DECLARABLE_UI_ROLES` in `bin/vshell-helper` is the set of roles it may name, not every role `target_roles` emits, and a key outside it is refused by name. Only a `source: curated` package is read this way; a generated palette derives every role. An undeclared role is derived from the palette as before.
