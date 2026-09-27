# D014: A plugin's source revision is a published snapshot; the engine keeps every revision it loaded

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: —

**Context**: A plugin edit must reach the screen without restarting the shell, and adding one plugin must not rebuild the others. Quickshell watches only files reached from `shell.qml` by static import, so nothing inside a plugin directory triggers its reload. QML caches every loaded file by URL: a query string on the entry point's URL reloads the entry point alone, while the sibling QML and JS files it imports keep resolving to their old URLs and their old bytes. Quickshell exposes no per-file cache eviction; Qt's `clearComponentCache` must not run while objects of the old types exist, and Quickshell's own reload makes a new engine, which drops every service's state. Restarting the whole shell on every plugin edit was rejected because a lock screen or a notification service would lose its state for an unrelated widget's edit.

**Decision**: `bin/vgsh-scan` hashes every file under a plugin directory except `.git` into a source revision and publishes each revision's files once under `$XDG_RUNTIME_DIR/vgsh-sources-<shell pid>/<revision>/`. The shell loads entry points from that directory, so a new revision is a new URL for the entry point and for every sibling it imports. Every slot keys on `<id>@<revision>`, so a rescan rebuilds only the plugins whose files changed. A scan retains the revisions of every listed plugin and of every live instance and removes the rest; a scan with an error removes nothing. The runner removes the roots earlier shells left before it starts a shell. The engine's own cache is accepted as unbounded within a session: each revision loaded leaves its compiled types in the engine until the shell restarts. Nothing on disk bounds that, and no figure is claimed for it.

**Rationale**:

- Whole-directory snapshots are the only way a changed sibling file is read again without a new engine.
- Keying every slot on the revision makes an edit reach the edited plugin alone and leaves every other instance, and every service's state, in place.
- Retaining live instances' revisions keeps lazily loaded files readable for as long as the instance exists.
- The runtime directory is per session and cleared at logout, so a crashed shell leaks nothing past the session.

**Revisit When**: A plugin's source tree is large enough that copying it per revision is felt, or a session accumulates enough edited revisions that the engine's retained types matter, or Quickshell offers per-URL cache eviction.

**Verification**: `scripts/test-vgsh-scan.py` pins the revision over content and executable bits and not `.git`, the snapshot's bytes, retention, pruning and the no-prune rule on error; `scripts/smoke/rows/sources.sh` edits a sibling file in the sandbox and reads the new value back from the rebuilt widget alone, then proves failed code is not retried until it changes and an unchanged plugin's files stay readable; `scripts/test-vgsh.sh` pins the runner's cleanup of earlier roots.

**References**: [D003](D003-everything-is-a-plugin.md), [D008](D008-validation-row-per-change.md)
