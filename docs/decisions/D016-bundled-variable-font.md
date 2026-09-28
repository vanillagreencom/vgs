# D016: Two bundled variable fonts

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: —

**Context**: The default theme names its typefaces. The previous shell named the system `monospace` alias, so the default look depended on the machine's font configuration, and one weight per role needs a family that carries every weight. The reference the text stack follows, plugins.omarchy.org, sets reading text in Inter and chrome in JetBrains Mono, so one family cannot draw both.

**Decision**: `shell/assets/fonts/JetBrainsMono-Variable.ttf` and `shell/assets/fonts/InterVariable.ttf` ship, each beside its OFL licence (`JetBrainsMono-OFL.txt`, `InterVariable-OFL.txt`), and `Theme` loads both. The default `font.family.mono` is `JetBrains Mono` and the default `font.family.sans` is `Inter Variable`, the family Qt reports for the Inter file. A theme names families and ships no font file; a family Qt does not list draws the bundled family its token's default names, and each substitution is logged once per theme. `tools/byte-ceiling-excludes` exempts `shell/assets/` from the commit-guards byte ceiling.

**Rationale**:

- The default theme draws the same on every machine.
- One variable file per family carries every weight the typography roles name.
- A substitute that is logged keeps a theme with a missing font readable instead of falling to Qt's own fallback unannounced, and substituting the token's own default keeps reading text in sans and chrome in mono.

**Revisit When**: A theme package format ships font files, or the bundled files' size is felt in the resident size budget.

**Verification**: `scripts/smoke/rows/theme.sh` reads both bundled families back from `Qt.fontFamilies()`, from `Theme.text.body.family` and from `Theme.text.label.family`, and proves an unavailable family is logged and replaced by the bundled family of its token. `scripts/qml-tests/tst_label.qml` reads each role's family back from a drawn `Label`.

**References**: [D015](D015-tokens-are-a-judged-table.md)
