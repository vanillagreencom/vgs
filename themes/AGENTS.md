# Theme changes

Read [../docs/architecture/theme.md](../docs/architecture/theme.md) for palette, overlay and output-path contracts. Read [../docs/architecture/agent-cli-themes.md](../docs/architecture/agent-cli-themes.md) for the agent CLI targets and the curated Claude Code files.

Per-theme app files intentionally share structure. Keep each package independently usable instead of extracting shared theme content.

A theme ported from an upstream takes every colour value, role mapping and curated app file from that upstream's published files, per [D017](../docs/decisions/D017-vendor-port-upstream-values.md). Name the upstream palette file and app files in [THEMES-ATTRIBUTION.md](THEMES-ATTRIBUTION.md).

A slot whose terminal meaning needs a different colour than the shell's derived roles and pi read goes in the package's `terminal-colors.toml`, never in `colors.toml`.

A curated package that publishes its own tone for a derived UI role states it in the package's `ui-roles.toml`. `DECLARABLE_UI_ROLES` in `bin/vshell_helper.py` is the set of roles it may name, not every role `target_roles` emits, and a key outside it is refused by name. Only a `source: curated` package is read this way, and only a curated save owns the file: it writes the declarations the package states, masks a built-in package's file when a user overlay states none, and removes a user package's file when it states none. A user overlay over a built-in package merges or replaces as the first invariant in [theme.md](../docs/architecture/theme.md) states. A generated palette derives every role and never writes, masks or removes the file at any save, so a colour edit or a wallpaper extract leaves it on disk unread and the apply names it once. An undeclared role is derived from the palette as before. Each value is a quoted six-digit `#rrggbb`; the leading `#` is optional but the quotes are not, since a bare `#` opens a TOML comment. An eight-digit `#rrggbbaa` is refused by name: VGS writes no alpha channel, and a tmux status bar or a terminal has nothing to blend it with.
