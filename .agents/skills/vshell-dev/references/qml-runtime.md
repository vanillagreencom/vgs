# QML runtime reference

## Entry path
- Root config: `quickshell/vshell/shell.qml`
- IPC: `quickshell/vshell/VGSIPC.qml`
- Shared paths: `quickshell/vshell/Common/Paths.qml`
- Theme tokens: `quickshell/vshell/Common/MethodTheme.qml`
- Settings/session: `quickshell/vshell/Common/SettingsData.qml`, `SessionData.qml`

## Service pattern
Services live in `quickshell/vshell/Services/`.
Use services for long-lived state, polling, IPC surfaces, and command bridges.
Keep UI modules free of duplicated process/state logic.

## Module pattern
Modules live in `quickshell/vshell/Modules/`.
Use modules for visible shell surfaces: settings, dash, launcher, control center, bar pieces, popouts.

## Command execution
Use `Process` for small external commands.
Use `Paths.vshellCli` for helper calls:

```qml
command: [Paths.vshellCli, "theme", "current", "--json"]
```

Do not use:

```qml
command: ["vshell", ...]
command: ["vgs", ...]
```

Reason: Quickshell runtime PATH can be sanitized, and the runtime should use `Paths.vshellCli`.

## Theme use
Bind UI colors/sizes to existing tokens:
- `Theme.surfaceText`
- `Theme.surfaceVariantText`
- `Theme.primary`
- `Theme.surfaceContainerHigh`
- `Theme.spacingS/M/L`
- `Theme.fontSizeSmall/Medium/Large`
- `Theme.iconSizeSmall/iconSize/barIconSize`

Avoid literal hex colors and raw pixel constants unless no token fits.

## Smoke test
```bash
scripts/qml-smoke.sh              # static QML parse check, always safe
scripts/qml-smoke.sh --nested     # + real shell in an isolated nested compositor
```

Bad: QML `ReferenceError`, `TypeError`, process failed to start, missing binary, import errors.

Never launch the shell directly (`qs -c vshell`, `qs -p quickshell/vshell`) while
a session shell is running: a second full instance fights the first for
WlSessionLock, the fade-to-lock overlay, and the idle/DPMS tiers, and strands
orphaned full-screen layer surfaces. `quickshell/vshell/shell.qml` refuses such a
duplicate at runtime, but the smoke script is the supported path.
