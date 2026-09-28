# D020: Theme apply swaps one state directory under a lock beside the theme file and writes the shell file last

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active

**Research**: VGS-458

**Context**: `vgsh theme apply` changes two readers at once: applications that read rendered files from a stable path, and the shell, which watches `~/.config/vgs/theme.json`. Two callers may apply at once, a terminal and the shell's own panel, and they need not share `XDG_RUNTIME_DIR`.

**Decision**: Apply renders into `~/.local/state/vgs/next-theme/` and swaps it over `theme/` by moving the old directory aside and renaming the stage into place, then writes `theme.name`, then copies the package's `theme.json` bytes over the shell's file by rename. One `flock` on `~/.config/vgs/theme.lock`, beside the file it guards, covers the whole apply; the file is never removed. An installed package hides the shipped package of its name even when the installed one is refused, except a reserved `vgs`.

**Rationale**:

- A lock under `XDG_RUNTIME_DIR` would let two callers with different runtime directories both write the theme file; the file's own directory is the one both must reach.
- Writing the shell file last means the shell restyles only after the application files exist, and a byte copy lets `modified` be a plain byte comparison.
- `rename(2)` cannot replace a non-empty directory, so the aside move is the smallest swap node offers; the window where `theme/` is absent is two renames long, and a failed second rename moves the old directory back.
- A refused installed package that fell back to the shipped one would apply a theme the user did not write; the list shows the refusal instead.

**Revisit When**: Applications need `theme/` present at every instant, which a symlink swap would give, or the lock must cover commands other than apply.

**Verification**: `scripts/test-vgsh.sh` covers the busy refusal with a lockless control, the byte copy with a re-serialising control, the stale stage, the shadowing and the reserved name.

**References**: [D019](D019-theme-packages-carry-plugin-trust.md)
