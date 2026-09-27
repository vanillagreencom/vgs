# D016: One bundled variable font

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: —

**Context**: The default theme names its typeface. The previous shell named the system `monospace` alias, so the default look depended on the machine's font configuration, and one weight per role needs a family that carries every weight.

**Decision**: `shell/assets/fonts/JetBrainsMono-Variable.ttf` ships with its OFL licence and `Theme` loads it. The default `font.family.mono` is `JetBrains Mono`. A theme names families and ships no font file; a family Qt does not list is logged once per theme and the bundled family draws in its place. `tools/byte-ceiling-excludes` exempts `shell/assets/` from the commit-guards byte ceiling.

**Rationale**:

- The default theme draws the same on every machine.
- One variable file carries every weight the typography roles name.
- A substitute that is logged keeps a theme with a missing font readable instead of falling to Qt's own fallback unannounced.

**Revisit When**: A theme package format ships font files, or the bundled file's size is felt in the resident size budget.

**Verification**: `scripts/smoke/rows/theme.sh` reads the bundled family back from `Qt.fontFamilies()` and from `Theme.text.body.family`, and proves an unavailable family is logged and replaced.

**References**: [D015](D015-tokens-are-a-judged-table.md)
