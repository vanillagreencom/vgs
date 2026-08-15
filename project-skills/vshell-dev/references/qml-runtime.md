# QML runtime reference

Structure truth — entrypoints, the runtime tree (`Common/`, `Services/`,
`Modules/`, `Widgets/`), data flow, and external-command rules — lives in
`docs/architecture/shell-architecture.md`; this file keeps the hands-on
patterns. Services own long-lived state, polling, IPC surfaces, and command
bridges; Modules are visible shell surfaces; keep UI modules free of duplicated
process/state logic.

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
scripts/qml-smoke.sh --nested --require-static
```

Bare `scripts/qml-smoke.sh` is a parse check only; `--nested` runs the real
shell in an isolated nested compositor and catches runtime QML errors —
`ReferenceError`, `TypeError`, failed process starts, missing binaries, import
errors. Never launch the shell directly (`qs -c vshell`, `qs -p quickshell/vshell`);
the rule and its recovery live in AGENTS.md § Never launch a second shell into
the live session, mode coverage in `scripts/qml-smoke.sh`'s header, and the
sandbox recipe in what that script prints when it cannot nest.
