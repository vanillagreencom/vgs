# D025: No user override layer merges over the applied theme

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: —

**Context**: `~/.config/vgs/theme.json` is the applied package's document. `vgsh theme apply <name>` replaces it with the package's bytes, and `vgsh theme list` reports it `modified` when a hand edit makes it differ ([themes.md § Runner](../architecture/themes.md#runner)). A user who wants one colour changed either hand-edits that file and loses the edit on the next apply, or copies a whole package. VGS-473 asked the owner whether a layer over the active theme should keep such a change.

**Decision**: No override layer exists. The shell draws the theme file alone, and the file is the applied package's document. A user who wants a colour changed copies a package into their own installed package under `${XDG_CONFIG_HOME:-~/.config}/vgs/themes/<name>/`, edits its `theme.json` and applies it. The copy follows the installed-package rules in [themes.md](../architecture/themes.md): the directory name equals the document `name`, an installed package hides the shipped package of its name, and a copy of `vgs` takes another name because an installed `vgs` is refused. `vgsh theme add`, `update` and `remove` manage such a package when it is a git checkout.

## Alternatives Considered

| Option | What it is | Outcome |
|---|---|---|
| A. No layer | The theme file is the package's document; a change is an edited copy installed as its own package | **Chosen** |
| B. Local token overrides | `~/.config/vgs/theme.local.json` holds token overrides that `ThemeLogic` judges with the document grammar and merges after the package; apply preserves it, list reports it, the themes plugin shows it | Rejected: a second source for every colour |
| C. Fork in the plugin | The themes plugin copies a package into a new installed package for the user to edit | Deferred: it produces an ordinary installed package, so it can be added later |

**Rationale**:

- One source of truth for every colour. The package the list names is the theme the shell draws, and `modified` answers whether the file still matches it. A merged local file would make every colour the product of two files, and every reader of the theme, the list, the apply, the plugin and each target renderer, would have to agree on the merge.
- v1's key-by-key overlays were its most expensive rule. Option B reintroduces the same shape for tokens.
- Option C can be added later without undoing anything. Its output is an installed package that option A already handles, so it needs no change to the judge, the apply or the list.

**Revisit When**: Users need to keep a local change while following upstream updates of an installed package, which `vgsh theme update` refuses on a checkout with local changes; or an application target needs a per-user value that no package can carry.

**Verification**: `scripts/test-vgsh.sh` pins that an installed package shadows the shipped package of its name, that an installed `vgs` shadows nothing, and that `theme list` reports `modified` by a byte comparison of the theme file with the named package's `theme.json`.

**References**: [D015](D015-tokens-are-a-judged-table.md), [D019](D019-theme-packages-carry-plugin-trust.md), [D020](D020-theme-apply-swaps-state-and-writes-the-shell-file-last.md), VGS-465 (themes panel), VGS-474 (`vgsh theme add`, `update`, `remove`)
