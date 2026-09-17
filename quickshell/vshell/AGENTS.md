# QML changes

Read [../../docs/architecture/shell.md](../../docs/architecture/shell.md) for runtime ownership and [../../docs/architecture/design-language.md](../../docs/architecture/design-language.md) for shared controls.

- Quickshell does not connect the engine's `Qt.quit()` or `Qt.exit()` signals to process termination.
- Use `Qt.resolvedUrl()` for QML assets and `Quickshell.shellDir` for filesystem paths passed to processes.
- `FolderListModel` treats a folder that is not there as the process's working directory, not as an error. It reports the swap through its own `folder` property. Compare `folder` against the folder asked for before reading the listing.
- `Process.exited` precedes `running` becoming false. A failed start emits no `exited`; handle unanswered probes through `running` and a bounded grace timer.
- Resolve helper calls through `Paths.vshellCli` instead of the inherited PATH.
