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
- `Qt.resolvedUrl()` resolves inside Quickshell's virtual filesystem. That is
  correct and idiomatic for QML-internal asset URLs — `FontLoader.source`,
  `Image.source` — and every bundled asset in this repo loads that way, so do
  not flag it there. It is wrong only where a real filesystem path is needed,
  such as one handed to a subprocess or compared against `/proc`: there it
  yields `qrc:/qs-blackhole/...`, which no process can open. Use
  `Quickshell.shellDir` for those.
- `Process` emits `exited` **before** `running` goes false, and a command that
  fails to start emits no `exited` at all — code that only handles `exited`
  hangs forever on a missing binary.
- Do not rely on PATH inherited by Quickshell. Call helpers through
  `Paths.vshellCli`, never a bare `vshell`.

Keep QML UI-focused. Parsing, generation, and privileged writes belong in
`bin/vshell-helper`, with QML shelling out to `vshell ...`. Flag new TOML/JSON
parsing or template rendering in QML as misplaced.
