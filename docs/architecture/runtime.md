# Runtime

Covers: scripts/**, bin/vgsh, shell/shell.qml, shell/Core/Compositor.qml, .github/workflows/**

Requirements for the shell process, the runner and the measurement tools, and the Quickshell facts the implementation rests on.

## Process

- One shell per session. `bin/vgsh run` takes no arguments, takes `flock` on `$XDG_RUNTIME_DIR/vgsh.lock`, writes its own pid as that file's only line, exports the pid as `VGSH_RUNNER_PID` and execs `qs` in the foreground, so the shell's pid equals the runner's. `shell.qml` draws, and accepts a state-changing IPC call, only when the two match; an unguarded instance answers read-only calls and refuses the rest with `refused: guard=unowned`. Every other `vgsh` command reads the pid from the lock file and addresses that instance alone; no pid, a dead pid or a failed call exits 69. A second `vgsh run` exits 75; an argument to `run` exits 2.
- Never kill Quickshell processes by name. Other Quickshell applications share the seat.
- Never start a second shell against the live session for a test. Validation runs inside the nested sandbox.
- `Qt.quit()` and `Qt.exit()` do nothing inside this Quickshell build: the log records `Signal QQmlEngine::quit() emitted, but no receivers connected`. A shell exit goes through the runner.
- `qs` buffers stdout when it is redirected, so a log captured by redirection stops after the first lines. The record is the per-instance file `$XDG_RUNTIME_DIR/quickshell/by-id/<id>/log.log`, line-flushed, found through `qs list -p shell -j`. `console.error` lands there as `ERROR qml:` and a QML exception as `WARN scene:`.

## Memory

- Growth lives in anonymous memory. A QML object count or a JavaScript heap snapshot measures none of it.
- A growth rate needs a window of at least 600 seconds. Shorter windows report sampling noise.
- Wayland events arrive as libwayland closures placed on the event queue of the target object and freed only when that queue is dispatched. In the previous shell an undispatched queue grew at 120 MiB per hour and a QML reload released it. A surface or object the shell creates is dispatched or destroyed; a plugin creates no surface of its own.
- Caches are bounded. A cache keyed by data other applications supply has an open key set and needs a ceiling.

## Performance

- One owner per watcher, poller and subprocess. Two components polling one source is a defect.
- A lookup that costs a process runs once per set, never once per item. `bin/vgsh-scan` reads every manifest in one process and the registry replaces its map whole.
- No disk walk per keystroke. A search keeps one long-lived index and cancels a stale query.
- No unconditional sleep on an apply path. Read the current value and skip the write and the wait when nothing changes.
- The scene-graph render threads are the frame cost. Memory growth is not on them, so a repaint change does not address a leak.

## Hyprland

- Every dispatch goes through `shell/Core/Compositor.qml`, which runs `hyprctl dispatch` and judges the reply by its text: anything but `ok` is logged with the request. Exit status alone says nothing; a refused dispatcher exits 0 with an error sentence.
- A dispatch while one is in flight is refused and logged, never queued.
- A Lua session and a classic session take different dispatcher syntax. `Hyprland.usingLua` selects it; a new dispatcher carries both forms.

## QML

- `FolderListModel` treats a missing folder as the process working directory and reports the swap through its `folder` property. Compare `folder` with the folder asked for before reading the listing.
- `Process.exited` fires before `running` becomes false. A command that fails to start emits no `exited`.
- A `Process` stdout parser is attached before the process starts; a null parser closes the channel for good.
- `Qt.resolvedUrl()` gives asset URLs. `Quickshell.shellDir` gives the filesystem path a subprocess needs.
- A JS object handed to `createObject` as an initial property crosses a QVariant conversion: functions vanish and nested lists stop being arrays. Assign such properties after creation.
- A property change handler runs before a binding that depends on the same property re-evaluates. Read the source property inside the handler.
- `Array.prototype.flatMap` is absent from this engine.

## Validation

- `scripts/validate` is the manifest. `scripts/qml-smoke.sh` is the nested row. It waits for the nested monitor before starting the shell, so no bar is built for the placeholder screen Qt invents when a compositor has no output yet.
- The sandbox needs `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` in the environment and Hyprland, `qs`, `hyprctl`, `python3`, `node`, `flock` and `setsid` on the path. A missing one exits 77 and names it.
- The sandbox runtime dir is a short name under the host's `XDG_RUNTIME_DIR`. A Unix socket path is limited to 107 bytes and Hyprland adds a 63-character signature under `hypr/`; a runtime dir under a long temporary path made Hyprland refuse IPC.
- Every check that spawns a process passes its environment explicitly, from `env -i`.
- A budget in a script names the machine and date it was measured on.
- The compositor keeps a destroyed layer surface in `hyprctl layers` with pid -1 until it drops it. A row that counts surfaces counts only layers with a client, and reads reserved geometry from `hyprctl monitors` for what the user feels.
