# QML changes

Read [../../docs/architecture/shell.md](../../docs/architecture/shell.md) for runtime ownership and [../../docs/architecture/design-language.md](../../docs/architecture/design-language.md) for shared controls.

- Quickshell does not connect the engine's `Qt.quit()` or `Qt.exit()` signals to process termination.
- Use `Qt.resolvedUrl()` for QML assets and `Quickshell.shellDir` for filesystem paths passed to processes.
- `Process.exited` precedes `running` becoming false. A failed start emits no `exited`; handle unanswered probes through `running` and a bounded grace timer.
- Resolve helper calls through `Paths.vshellCli` instead of the inherited PATH.
