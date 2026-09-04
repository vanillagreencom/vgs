# quickshell/vshell/

The Quickshell 0.3.0 QML runtime. Services own long-lived state, polling, IPC surfaces and command bridges; modules are visible surfaces that bind to them; widgets are the shared primitives. Structure and invariants: [../../docs/architecture/shell.md](../../docs/architecture/shell.md).

This is Quickshell 0.3.0, not plain Qt or QML. Each difference below has already produced a wrong review suggestion here:

- `Qt.quit()` and `Qt.exit()` do not end the process. Quickshell leaves the engine's quit and exit signals unconnected, so the engine logs that nothing is listening and the process keeps running. Never propose them as a way to terminate the shell.
- `Qt.resolvedUrl()` resolves inside Quickshell's virtual filesystem. That is correct and idiomatic for QML-internal asset URLs, and every bundled asset here loads that way. It is wrong only where a real filesystem path is needed, such as one handed to a subprocess or compared against a process path; use `Quickshell.shellDir` there.
- `Process` emits `exited` before `running` goes false, and a command that fails to start emits no `exited` at all — so code that only handles `exited` hangs forever on a missing binary. Key an unanswered probe on `running` plus a grace timer.
- Do not rely on the `PATH` Quickshell inherits. Call helpers through `Paths.vshellCli`, never a bare command name.

Keep this tree UI-focused. Parsing, generation and privileged writes belong in `bin/vshell-helper`, with QML shelling out to `vshell ...`; new format parsing or template rendering here is misplaced. Bind colours and sizes to the tokens in `Common/Theme.qml` and `Common/Appearance.qml` rather than to literals — [../../docs/architecture/design-language.md](../../docs/architecture/design-language.md) says which token carries which intent.
