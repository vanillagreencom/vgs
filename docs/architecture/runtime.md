# Runtime

Covers: scripts/test-vgsh-scan.py, scripts/test-vgsh.sh, scripts/vgsh-rows.sh, bin/vgsh, shell/shell.qml, shell/Core/ServiceGate.qml, shell/Hosts/ServiceHost.qml

Requirements for the shell process, the runner and the measurement tools, and the Quickshell facts the implementation rests on; the facts its QML rests on are in [runtime-qml.md](runtime-qml.md), and the Hyprland facts in [runtime-hyprland.md](runtime-hyprland.md).

## Process

- One shell per session. `bin/vgsh run` takes no arguments, takes `flock` on `$XDG_RUNTIME_DIR/vgsh.lock`, writes its own pid as that file's only line, exports the pid as `VGSH_RUNNER_PID`, which every process the shell starts inherits but the programs it opens for the user ([packages.md § Running a plan](packages.md#running-a-plan)), and execs `qs` in the foreground with Quickshell's file watcher and reload popup disabled, so the shell's pid equals the runner's. The lock's descriptor is not close-on-exec, so every process the shell starts inherits it, and the lock stays held until the shell and every process it started have exited. On host cachy on 2026-09-29, a `/proc/<pid>/fd` scan during two nested smokes found children of the sandbox `qs`, such as `bash .../slow-download theme wallpapers --json nord`, holding the sandbox's `vgsh.lock`. `shell.qml` draws, and accepts a state-changing IPC call, only when the two match; an unguarded instance answers read-only calls and refuses the rest with `refused: guard=unowned`. Before it execs `qs`, the runner creates the configuration and the state directories, whose files the shell watches from its start ([runtime-qml.md](runtime-qml.md)), and removes the plugin source snapshot roots earlier shells left under `$XDG_RUNTIME_DIR`. Quickshell 0.3.1 carries the session lock across a reload: `WlSessionLock::onReload` adopts the old lock manager, then `realizeLockTarget` calls `unlock()` when the new engine's `locked` is false (`src/wayland/session_lock.cpp`). VGS starts `SessionLock.lockRequested` false, so a file-watcher reload while locked can unlock the session. Core QML edits need `vgsh restart`: it refuses while locked with exit 4, stops the recorded pid, waits for the instance lock, relaunches through `hyprctl dispatch` in the session's dialect so the shell keeps the session environment, prints the new pid once the new shell answers as the guarded instance and does not supervise crashes. Every `vgsh` command that contacts the shell reads the pid from the lock file and addresses that instance alone; no pid, a dead pid or a failed call exits 69. `vgsh plugin validate`, `add`, `update` and `remove` work with no shell running; `add`, `update` and `remove` then end with `shell=not-running`. `vgsh theme list`, `apply`, `reload`, `add`, `update` and `remove` never contact the shell; their lock is [themes.md § Runner](themes.md#runner). A second `vgsh run` exits 75; an argument to `run` or `restart` exits 2.
- `vgsh run`, and `vgsh restart` before it stops the shell, first check the floor in the `preflight_floor` table of `bin/vgsh`: Quickshell 0.3.1, a running Hyprland 0.56, node 18, and python3 and git present. Below it they exit 78 with `vgsh: refused: preflight=<tool> have=<version|none|unknown> need=<version|present>`. The probes run at once, and the refusal names the first failing row in table order. `run` refuses before the lock, the directories and the snapshot roots. Every package recipe carries these floors as dependency constraints, and `scripts/check-packaging.js` fails until a bumped floor reaches the recipes ([distribution-arch.md](distribution-arch.md)). Outside Hyprland the check refuses ([D001](../decisions/D001-hyprland-only.md)); the smoke harness hands the shell the nested Hyprland, so it needs no skip. Node, python3 and git are hard runtime dependencies: [D009 § Revisit Outcome](../decisions/D009-one-manifest-judge-under-node.md#revisit-outcome-2026-09-28). Autostart is `hl.on("hyprland.start", function () hl.exec_cmd("vgsh run") end)` in `hyprland.lua`; VGS ships no systemd unit. The first run adds one line to the top of an existing `hyprland.lua` that loads the Hyprland layer, and `vgsh hypr unwire` removes it: [hyprland.md](hyprland.md). The README's autostart line must equal this one: [install-guide.md](install-guide.md).
- `bin/vgsh` holds the theme lock on descriptor 9 for the judge it execs, and `bin/vgsh-theme-judge`'s `LOCK_FD` names the same number. A child node spawns keeps a descriptor above 2 that the parent holds open without close-on-exec, and a spawn's `ignore` slot above 2 leaves it so: node 26.10.0 passed descriptor 300 to a child under both. Node marks its inherited descriptors 0 to 16 close-on-exec at startup (strace of node 26.10.0 on this host, 2026-09-27), which covers 9 on that build. The judge binds its own `/dev/null` descriptor to slot 9 of every reload hook, so no hook holds the lock on any build.
- Never kill Quickshell processes by name. Other Quickshell applications share the seat.
- A floating TUI needs `xdg-terminal-exec`, a default terminal whose desktop entry maps `--app-id`, `gum`, `setsid` and `script`: [tui.md § The window](tui.md#the-window).
- Never start a second shell against the live session for a test. Validation runs inside the nested sandbox.
- `Qt.quit()` and `Qt.exit()` do nothing inside this Quickshell build: the log records `Signal QQmlEngine::quit() emitted, but no receivers connected`. A shell exit goes through the runner.
- `qs` buffers stdout when it is redirected, so a log captured by redirection stops after the first lines. The record is the per-instance file `$XDG_RUNTIME_DIR/quickshell/by-id/<id>/log.log`, line-flushed, found through `qs list -p <checkout>/shell -j`. `console.error` lands there as `ERROR qml:` and a QML exception as `WARN scene:`.

## Memory

Where the shell's memory sits, how to measure it and the growth invariants are in [memory.md](memory.md). The cache rule is in [plugins.md § Budgets](plugins.md#budgets).

## Performance

- One owner per watcher, poller and subprocess. Two components polling one source is a defect.
- A lookup that costs a process runs once per set, never once per item. `bin/vgsh-scan` reads every manifest and probes every declared command in one process, and the registry replaces its map whole.
- No disk walk per keystroke. A search keeps one long-lived index and cancels a stale query.
- No unconditional sleep on an apply path. Read the current value and skip the write and the wait when nothing changes.
- The first bar comes before every service. Bars, their widgets and backgrounds build in the turn the first scan ends. `ServiceHost` builds no service until `shell/Core/ServiceGate.qml` releases the services: once every bar built for that scan has presented its first frame, at once when that scan built no bar, and at a 358 ms deadline otherwise, which logs a warning naming each bar host that did not present. The release logs `plugins: services released reason=<first-frame|no-bar|deadline> waited_ms=<ms>`. It happens once per shell process, so a later enable, rescan, screen change or bar rebuild builds services at once. At start a surface plugin therefore claims an exclusive capability before any service, and the theme follow on `scanFinished` never waits for the release: [D047](../decisions/D047-services-build-after-the-first-bar-frame.md).

## Hyprland

The Hyprland facts the shell rests on and the rules for every dispatch are in [runtime-hyprland.md](runtime-hyprland.md).

## Notifications

What the Quickshell 0.3.1 notification server does, from its source, is in [notification-actions.md § Quickshell 0.3.1](notification-actions.md#quickshell-031).

## QML

The Quickshell and Qt facts the QML rests on are in [runtime-qml.md](runtime-qml.md).

## Validation

The checks are in [validation.md](validation.md), and the nested sandbox, its harness and the smoke's verdicts in [validation-smoke.md](validation-smoke.md).
