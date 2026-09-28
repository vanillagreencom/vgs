# D031: An installed theme's curated file is dropped on a target whose files run code

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: VGS-495, [docs/plans/v2-omarchy-audit.md § Theme install, update, remove and trust](../plans/v2-omarchy-audit.md#theme-install-update-remove-and-trust)

**Context**: [D019](D019-theme-packages-carry-plugin-trust.md) wrote every curated target file byte for byte and gave any package plugin trust. Some target files load or run code when their application starts: `neovim.lua`, `wezterm.lua`, `emacs.el`, a terminal configuration that names the program it launches. Users install themes more casually than anything else. Unlike a plugin under [D007](D007-install-runs-no-plugin-code.md), a theme has no step that lands it disabled for review. `vgsh theme update` fast-forwards an installed package, and follow applies it again with no explicit apply. New code from a theme's author would therefore run at the next editor or terminal start. Omarchy's `omarchy-theme-set` drops every such file from a cloned theme (`INSTALLED_THEME_DENIED` and every `*.lua`) and renders the template in its place. Its `test/shell.d/theme-staging-test.sh` fails on a generated file it has not classified as code or colour.

**Decision**: Every `target.json` carries the required boolean `runsCode`, and `acceptTarget` refuses a target without it, so no target ships unclassified. On a `runsCode` target, `renderTarget` drops an installed package's curated file and writes the rendered template in its place. It does not judge the dropped file's shape, and it names the file's destination in `dropped` on the target's apply row. A shipped package keeps its curated files, and an installed package keeps them on every other target. This supersedes D019's trust clause alone: package shape, terminal slots and the reserved `vgs` name stand.

**Rationale**:

- The template renders every placeholder already, so dropping a curated file costs only the author's hand-written extras on that target.
- The classification sits beside the target it describes. A new target that does not state it is refused by `bin/vgsh-theme-judge packages themes` in validation, as Omarchy's test refuses an unclassified template.
- Shipped packages are reviewed with the code that ships them, so they keep their curated files.
- Naming the drop on the apply row tells the owner why a theme looks plainer than its author's screenshots.
- VGS drops by package source, not by the git checkout Omarchy tests for. Every package under the configuration home's `themes/` is installed, one a user wrote by hand included, since nothing tells a copied checkout from a hand-written directory. A user's own code belongs in the user's own configuration, which the include line leaves in force.

**Revisit When**: Packages carry signatures or a trusted-author list; or an installed theme needs a code-carrying file with no template equivalent.

**Verification**: `scripts/test-theme-render.js` covers the `runsCode` rules and the drop, with a control per rule; `scripts/test-vgsh-targets.sh` covers an installed package's curated `neovim.lua` dropped and reported, a shipped package's kept, and an unclassified target refused; `bin/vgsh-theme-judge packages themes` refuses an unclassified shipped target.

**References**: [D007](D007-install-runs-no-plugin-code.md), [D010](D010-facade-scope-not-sandbox.md), [D019](D019-theme-packages-carry-plugin-trust.md)
