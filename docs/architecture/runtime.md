# Runtime

Covers: scripts/validate, scripts/qml-smoke.sh, scripts/smoke/, scripts/qml-library.js, scripts/test-qml-library.js, scripts/check-manifests.js, scripts/check-plugin-boundary.py, scripts/test-check-manifests.js, scripts/test-check-plugin-boundary.py, scripts/test-dispatch.js, scripts/test-plugin-logic.js, scripts/test-vgsh-scan.py, scripts/test-vgsh.sh, scripts/test-vgs-plugin.py, scripts/test-validate.sh, bin/vgsh, shell/shell.qml, shell/Core/Compositor.qml, shell/Core/Dispatch.js, .github/workflows/**

Requirements for the shell process, the runner and the measurement tools, and the Quickshell facts the implementation rests on.

## Process

- One shell per session. `bin/vgsh run` takes no arguments, takes `flock` on `$XDG_RUNTIME_DIR/vgsh.lock`, writes its own pid as that file's only line, exports the pid as `VGSH_RUNNER_PID` and execs `qs` in the foreground, so the shell's pid equals the runner's. `shell.qml` draws, and accepts a state-changing IPC call, only when the two match; an unguarded instance answers read-only calls and refuses the rest with `refused: guard=unowned`. Before it execs `qs`, the runner removes the plugin source snapshot roots earlier shells left under `$XDG_RUNTIME_DIR`. Every `vgsh` command that contacts the shell reads the pid from the lock file and addresses that instance alone; no pid, a dead pid or a failed call exits 69. `vgsh plugin validate`, `add`, `update` and `remove` work with no shell running; `add`, `update` and `remove` then end with `shell=not-running`. A second `vgsh run` exits 75; an argument to `run` exits 2.
- Never kill Quickshell processes by name. Other Quickshell applications share the seat.
- Never start a second shell against the live session for a test. Validation runs inside the nested sandbox.
- `Qt.quit()` and `Qt.exit()` do nothing inside this Quickshell build: the log records `Signal QQmlEngine::quit() emitted, but no receivers connected`. A shell exit goes through the runner.
- `qs` buffers stdout when it is redirected, so a log captured by redirection stops after the first lines. The record is the per-instance file `$XDG_RUNTIME_DIR/quickshell/by-id/<id>/log.log`, line-flushed, found through `qs list -p <checkout>/shell -j`. `console.error` lands there as `ERROR qml:` and a QML exception as `WARN scene:`.

## Memory

Where the shell's memory sits, how to measure it and the growth invariants are in [memory.md](memory.md). The cache rule is in [plugins.md § Budgets](plugins.md#budgets).

## Performance

- One owner per watcher, poller and subprocess. Two components polling one source is a defect.
- A lookup that costs a process runs once per set, never once per item. `bin/vgsh-scan` reads every manifest in one process and the registry replaces its map whole.
- No disk walk per keystroke. A search keeps one long-lived index and cancels a stale query.
- No unconditional sleep on an apply path. Read the current value and skip the write and the wait when nothing changes.

## Hyprland

- Every dispatch goes through `shell/Core/Compositor.qml`, which runs `hyprctl dispatch` and judges the reply by its text: anything but `ok` is logged with the request. Exit status alone says nothing; a refused dispatcher exits 0 with an error sentence.
- `shell/Core/Dispatch.js` builds every request and speaks both dialects. Each argument must match a pattern that admits no quote, backslash, space or comma, so no argument ends the Lua string or the classic argument list it is spliced into. Every dispatcher it holds is one a plugin may call through its `compositor` capability; `Dispatch.PLUGIN_DISPATCHERS` is that list. `scripts/test-dispatch.js` pins both syntaxes of every dispatcher and one refusal per argument class.
- Dispatches wait in order behind one running process. `Dispatch.QUEUE_LIMIT` bounds waiting requests; overflow returns and logs `refused: dispatch-queue=full`. Each reply and exit belongs to the active request until `runningChanged` reports false, including a failed start.
- A Lua session and a classic session take different dispatcher syntax. `Hyprland.usingLua` selects it; a new dispatcher carries both forms. The Lua window dispatchers accept unknown table keys without complaint and `hl.dsp.window.move` answers `ok` for an address that names no window, so only a read of the compositor's state after the reply proves a dispatcher acted.

## QML

- `FolderListModel` treats a missing folder as the process working directory and reports the swap through its `folder` property. Compare `folder` with the folder asked for before reading the listing.
- Restart a `Process` from `runningChanged` when `running` is false, as the [Process reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/) requires. Its implementation clears the process before emitting `exited`, then emits `runningChanged`. A command that fails to start emits only `runningChanged`.
- A `Process` stdout parser is attached before the process starts; a null parser closes the channel for good.
- `Qt.resolvedUrl()` gives asset URLs. `Quickshell.shellDir` gives the filesystem path a subprocess needs.
- A JS object handed to `createObject` as an initial property crosses a QVariant conversion: functions vanish and nested lists stop being arrays. Assign such properties after creation.
- A dependent binding may still hold its old value when a property change handler runs. Read the source property inside the handler; [Qt specifies no binding evaluation order](https://doc.qt.io/qt-6/qtqml-syntax-propertybinding.html).
- `Array.prototype.flatMap` is absent from this engine.
- Qt reads an eight-digit colour string as `#aarrggbb`, alpha first. The design system's portable colours are `#rrggbbaa`; `Theme.toColor` is the one place that reorders them.
- A frozen JavaScript object does not protect the channels of a QML colour value inside it: a write to `frozen.accent.r` changes the value read back. Publish a colour as a string.
- A `ShapePath` with `scale` above one loses a stroke under one path unit; scale the `Shape` item with a transform instead. A file in a module subdirectory sees no sibling type of the module by directory alone and imports the module.
- A Qt popup with `popupType: Popup.Window` is placed once on Wayland and never moved: Qt leaves repositioning to the server and sends no reposition, and its position is what the parent window's bounds allow, so a popup taller than a bar is pushed into the bar. A Quickshell `PopupWindow` anchored to the item places below the bar and moves on `anchor.updateAnchor()`; the overlays use it, with a negative bottom anchor margin as the gap.
- A pointer handler declared with a `parent` binding crashes the engine while the parent is still null; make it with `createObject` once the parent is known. A popup of a fresh bar surface opens only after the surface has drawn and taken one pointer event, so a row clicks the widget before it opens a popup.
- `ignoreWarning` in a QML test case catches warnings alone; a `console.error` is a critical message it does not catch.

## Validation

- `scripts/validate` owns the commands and their input globs. Local runs and CI select affected rows with `--changed BASE`; shared dependencies select every listed consumer, and unknown inputs or a failed diff select the full area. `scripts/test-validate.sh` checks selection and plants a forbidden import that escapes when its dependency edge is removed. The nested smoke stays one integration suite: its rows share state and run in a fixed order. `scripts/smoke/harness.sh` owns startup, teardown and shared readers. It waits for the nested monitor before starting the shell, so no bar is built for Qt's placeholder screen.
- `scripts/qml-unit.sh` runs the QML unit tests under `qmltestrunner` on the offscreen platform, the area `unit`: Qt with no Wayland session. `offline` leaves it out, so CI runs it nowhere; a missing runner exits 77. A grab of a rendered item needs the test case nested under a root item and one `wait` before the grab; a test case that is the file's root grabs an unrendered image.
- `scripts/smoke/fixtures/plugins/` holds the plugins copied into the sandbox. The offline manifest and boundary rows check every fixture. `scripts/smoke/rows/failed-builds.sh` asserts runtime refusal for `acme.broken` and `acme.nowidget`: their manifests and imports are valid, but their entry points lack properties the host assigns. These fixtures have no offline exemption.
- The sandbox needs `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` in the environment and Hyprland, `qs`, `hyprctl`, `python3`, `node`, `flock`, `setsid`, `git`, `dbus-daemon`, `gdbus`, `cc`, `wayland-scanner`, `wtype` and `pkg-config` with `wayland-client` on the path. A missing one exits 77 and names it. `wtype` types keys on the nested seat, so a row reaches a focused input; the pointer helper also moves the pointer without a press, so a row hovers an item.
- The harness builds `scripts/smoke/pointer/click.c` into the sandbox: one click through the nested compositor's virtual pointer protocol, run only with the nested socket in its environment, so a row can click a widget or click outside a menu without any tool that reaches the live seat. The shell alone resolves `hyprctl` through a stand-in directory on its path, so a row can replace the command with one that cannot start and prove the dispatch queue survives it.
- The sandbox runs two private D-Bus daemons with no service directories as the session and system buses, so the shell's notification server and polkit agent never reach the user's buses and nothing is activated on them.
- A nested compositor that fails to allocate its output buffers stops laying out surfaces, and every geometry row after it reads zeros. A row that reads positions, sizes or reserved space runs under `geometry`; when every failed row is a geometry row and the nested compositor's own log holds the allocation failure, the smoke exits 77 with `nested-compositor=buffer-allocation-failed`. Any other failure exits 1. Re-run it; 77 is not a pass.
- `scripts/smoke/harness.sh` copies the shell into the sandbox and adds `scripts/smoke/Probe.qml`. The observer owns test counters, instance readback and form setup. A generated alias exposes the user file view only in this copy. The shipped shell contains none of these test methods.
- Hidden nested windows need the host Hyprland's `render_unfocused` window rule for class `aquamarine`. It supplies frame callbacks even on an inactive workspace or hidden scratchpad; `misc:render_unfocused_fps` controls the rate. Without it, keep the window visible. Put scratchpad routing, `no_initial_focus` and activation suppression in the host configuration; the smoke never opens a host workspace or changes host focus. Avoid `no_focus` when manual selection and movement are required. A row whose subject requires a drawn frame runs under `render`, which reads the bar windows' frame count through `frames` before and after; when every failure is a geometry or render row and a failed render row drew no frame, the smoke exits 77 with `nested-window=not-drawn`.
- The smoke's log check fails on every error line except those a row provokes on purpose and names in `expected_errors`.
- The sandbox runtime dir is a short name under the host's `XDG_RUNTIME_DIR`. The short path leaves space for Hyprland's signature and socket names.
- Every check that spawns a process passes that process an explicit environment, never the developer's live one.
- A budget in a script names the machine and date it was measured on. Each latency reading in the smoke carries its poll interval: 10 ms for the first bar, one `qs ipc` round trip for the build records.
- The compositor keeps a destroyed layer surface in `hyprctl layers` with pid -1 until it drops it. A row that counts surfaces counts only layers with a client, and reads reserved geometry from `hyprctl monitors` for what the user feels.
