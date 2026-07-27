# Attribution

The VGS backend daemon is adapted from the Go core of
`AvengeMedia/DankMaterialShell`, commit
`1cc9218ff6192477d52b025f5fbbc286df0f50ef`.

All package/module names, socket/env/desktop identifiers, PID/session file
names, and configuration paths have been renamed to VGS-owned names. The socket
env exported to Quickshell is `VGS_SOCKET`; no upstream socket name, PID file,
config path, desktop ID, or environment variable is exposed.

Explicitly **not** ported from upstream:

- `matugen`, `themes.*`, `theme.auto`, and any theme/wallpaper generation model.
  VGS theming is owned by `bin/vshell-helper`, `VGSThemeService`, and
  `vshell theme`.
- Upstream multi-compositor shell orchestration. VGS implements its Niri paths
  in VGS-owned QML and helper code instead of exposing upstream runtime names.

Upstream is MIT-licensed; the retained license text and copyright
(Copyright (c) 2025 Avenge Media LLC) live at `quickshell/vshell/LICENSE`,
which covers this adaptation as well. See `docs/ATTRIBUTION.md` for the full
lineage.

This file is exempt from `scripts/check-naming.sh` (it carries upstream lineage
by design); runtime code, config, and generated paths must not.
