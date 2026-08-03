---
applyTo: "quickshell/vshell/**/*.qml"
---

# Quickshell QML

This is **Quickshell 0.3.0, not plain Qt/QML**. Each difference below has
already produced a wrong review suggestion on this repo:

- `Qt.quit()` and `Qt.exit()` do **not** end the process. Quickshell leaves
  QQmlEngine's quit/exit signals unconnected; the engine logs "no receivers
  connected to handle it" and the process keeps running. Never suggest them as
  a way to terminate the shell.
- `Qt.resolvedUrl()` resolves inside Quickshell's virtual filesystem and yields
  `qrc:/qs-blackhole/...`, which is not a runnable path. Derive filesystem
  paths from `Quickshell.shellDir`.
- `Process` emits `exited` **before** `running` goes false, and a command that
  fails to start emits no `exited` at all — code that only handles `exited`
  hangs forever on a missing binary.
- Do not rely on PATH inherited by Quickshell. Call helpers through
  `Paths.vshellCli`, never a bare `vshell`.

Keep QML UI-focused. Parsing, generation, and privileged writes belong in
`bin/vshell-helper`, with QML shelling out to `vshell ...`. Flag new TOML/JSON
parsing or template rendering in QML as misplaced.
