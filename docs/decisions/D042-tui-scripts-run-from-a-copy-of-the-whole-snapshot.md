# D042: A plugin's floating TUI script runs from a copy of its whole snapshot

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: [docs/plans/v2-platform-roadmap.md](../plans/v2-platform-roadmap.md) § vgs.devtools

**Refines**: [D033](D033-floating-tuis-are-core.md)

**Context**: [D033](D033-floating-tuis-are-core.md) runs a plugin's script from a private copy of its snapshot's `tui/` directory, so a `vgsh restart`, which removes old snapshots, cannot pull a file from under the script. The `vgs.devtools` TUI script runs the plugin's engine, `bin/devtools`, which reads `catalog.json` and `CatalogLogic.js` at the plugin's root. A copy of `tui/` alone holds none of them, so the script has no file of its own plugin to run.

**Decision**: `vgsh-tui present` copies the whole snapshot into the private directory, and `VGS_PLUGIN_DIR` names that copy. argv[0] must still resolve to an executable file inside the copy's `tui/` directory, so the scripts a manifest declares stay the only entry points.

**Rationale**:
- Every plugin whose TUI runs its own program or reads its own data meets the same need, so the core answers it once instead of each plugin working round it.
- The copy keeps D033's guarantee for every file the script reaches, not only the files beside it.
- Rejected: the service passes its snapshot path as a TUI argument. A restart between the request and the engine's start removes that path, which is the race the copy exists to close.
- Rejected: links in `tui/` to files at the plugin root. `bin/vgsh-scan` follows links when it publishes a snapshot, so the copy would hold them, but the engine would then need two layouts, one in the source tree and one in the copy.
- Rejected: the engine and catalog inside `tui/`. The panel reads the catalog and `CatalogLogic.js` from the plugin root, so the files would move away from their other readers.

**Revisit When**: A plugin with a TUI ships files large enough that a copy per launch delays the window.

**Verification**: `scripts/test-vgsh-tui.sh` runs a plugin script that removes its snapshot and then sources a file at the snapshot's root, with a control that copies only `tui/`.

**References**: [D033](D033-floating-tuis-are-core.md), [D014](D014-source-revisions-are-published-snapshots.md), [tui.md § A plugin's script](../architecture/tui.md#a-plugins-script), VGS-556.
