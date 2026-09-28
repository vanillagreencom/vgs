# D021: A theme apply writes beside each destination and the shell document last

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active

**Research**: VGS-461

**Refines**: [D020](D020-theme-apply-swaps-state-and-writes-the-shell-file-last.md)

**Context**: An apply now lands one file per enabled application target and keeps one include line in each application's own configuration file. Those files live in a dotfile manager's tree as often as not, reached through a symlink, and one target that cannot render must not cost the others or the shell.

**Decision**: Every write is staged beside its destination and moved in by rename. Every enabled target renders in memory first. Its files join `theme.json` and `terminal.json` in `next-theme/`, the sibling of `theme/`, so the swap is one rename on one filesystem. After the swap and `theme.name`, the include line is kept in each landed target's configuration file. A symlink is resolved, and the file it names is replaced through a temporary file beside it, with its mode kept. The shell document is written last. Nothing else in an application's directory is written. A target that fails to render lands no file and reports `failed`. The apply is then `partial` and exits 3.

**Rationale**:

- A rename within one directory is atomic and never crosses a filesystem, so no reader sees half a file. `vgsh plugin add` stages beside its destination for the same reason.
- Replacing the resolved file keeps a dotfile manager's link a link. Replacing the link itself would sever the managed file (VGS-307 in v1).
- A stable include path means a later apply changes nothing in the application's directory. The line is asserted on every apply, so a hand edit that drops it is repaired.
- The shell restyles only after every application file and include line is in place, so the displayed theme never runs ahead of the applications.
- An in-place `write(2)` would keep the inode, but a crash could leave the user's configuration half-written. The rename trades the inode for atomicity.

**Revisit When**: An application reads its configuration through a hard link or watches its inode, or a target needs its include line somewhere other than the file's first line.

**Verification**: `scripts/test-vgsh.sh` covers the partial result, the symlinked edit with a control that replaces the link, and the wiring on unchanged bytes with a written-only control. `scripts/smoke/rows/themes.sh` covers a real partial apply through the `theme` capability.

**References**: [D020](D020-theme-apply-swaps-state-and-writes-the-shell-file-last.md), [D019](D019-theme-packages-carry-plugin-trust.md)
