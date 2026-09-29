# D009: One manifest judge shared by the shell and the scripts, run under node

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: Manifest validation, configuration merging and enablement are needed by the shell at runtime and by the checks offline. Two implementations would drift.

**Decision**: `shell/Core/PluginLogic.js` is a pure `.pragma library` file with no QML object and no I/O. The shell imports it; `scripts/test-plugin-logic.js`, `scripts/check-manifests.js` and `vgsh plugin validate` run it under node. Node is a runtime dependency of `vgsh`: see the revisit outcome below.

**Rationale**:

- One judge per question; a second copy is a twin even when both agree.
- Pure functions test under node in milliseconds without a compositor.

**Revisit When**: A decision needs QML types (a `ShellScreen`, a `Process`) that node cannot host, or node becomes unavailable on the reference machine.

**Verification**: `scripts/test-plugin-logic.js` and `scripts/check-manifests.js` both load the same file.

**References**: [D011](D011-native-manifest-no-cross-shell-compatibility.md)

## Revisit Outcome (2026-09-28)

The decision holds: one judge per question, run under node. Node and python3 are runtime dependencies of `vgsh`, not validation-time ones: every `theme` verb but `browser-policy`, `plugin add`, `update`, `remove` and `validate`, and `hypr wire` and `unwire` run a node judge, and `bin/vgsh-scan` and `plugin list` run python3. The shell runs `bin/vgsh-scan` on every plugin scan and the notifications plugin's Slack photo helper under node. Both are hard dependencies in every package, and `vgsh run` refuses to start below the floor its preflight checks ([runtime.md § Process](../architecture/runtime.md#process)). The judges are not rewritten into bash, because the judge must be the file the shell loads.

Node 18 is the floor, and node 17 is not measured. Node 18.0.0, 18.20.8, 20.20.2, 22.23.3 and 24.21.0 each pass all 31 runtime suites, `scripts/test-*.js`, `scripts/check-manifests.js` and `scripts/test-vgsh*.sh`. Node 16.20.2 fails `scripts/test-vgsh-reload.sh`: its `fs.rmSync(file, { force: true })` returns on `EACCES`, so a failed removal of the pending-reload file is not refused. Each node binary ran first on PATH in `podman run --rm --userns=keep-id` of `docker.io/library/node:18-bookworm` (Python 3.11.2, git 2.39.5) on `cachy` (AMD Ryzen 9 9950X), 2026-09-28.

Omarchy (`basecamp/omarchy`) starts its shell from `hl.on("hyprland.start", ...)` in `default/hypr/autostart.lua` through `bin/omarchy-launch-shell`, which checks no version (e332dc9): Omarchy installs pinned packages on the one distribution it supports. VGS runs on distributions it does not control, so `vgsh run` checks the floor before it starts.
