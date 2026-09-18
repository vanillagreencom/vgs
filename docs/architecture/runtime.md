# Runtime

Covers: scripts/**

Requirements for the shell process and its measurement tools. The measurement scripts exist under `scripts/`; the V2 runner, shell and nested validation harness are not implemented yet. Add their paths to `Covers:` when they land. The rules below govern that implementation; they do not claim that its checks already exist.

## Process

- One shell per session. The runner takes the instance lock before it starts Quickshell, and the shell draws only when its parent is the lock holder. A second instance competes for session resources and can leave the desktop black.
- Never kill Quickshell processes by name. Other Quickshell applications share the seat.
- Never start a second shell against the live session for a test. Validation runs inside a nested compositor with the instance guard disabled by the sandbox alone.
- `Qt.quit()` and `Qt.exit()` do nothing inside Quickshell. A shell exit goes through the runner.

## Memory

- Quickshell links jemalloc. Resident size reports live data plus retained pages, falls in steps, and is not a leak measurement. The process high-water mark is the number a session reached.
- Growth lives in anonymous memory. A QML object count or a JavaScript heap snapshot measures none of it.
- A growth rate needs a window of at least 600 seconds. Shorter windows report sampling noise.
- Wayland events arrive as libwayland closures placed on the event queue of the target object and freed only when that queue is dispatched. In the previous shell an undispatched queue grew at 120 MiB per hour and a QML reload released it. A surface or object the shell creates is dispatched or destroyed; a plugin creates no surface of its own.
- Caches are bounded. A cache keyed by data other applications supply, such as icon names from notifications, has an open key set and needs a ceiling.

## Performance

- One owner per watcher, poller and subprocess. Two components polling one source is a defect.
- A lookup that costs a process runs once per set, never once per item. The icon theme index loads as one map and replaces itself whole, so bindings re-evaluate once.
- No disk walk per keystroke. A search keeps one long-lived index and cancels a stale query.
- No unconditional sleep on an apply path. Read the current value and skip the write and the wait when nothing changes.
- The scene-graph render threads are the frame cost. Memory growth is not on them, so a repaint change does not address a leak.

## Hyprland

- Judge a `hyprctl` reply by its text, not its exit status. A refused keyword and a refused output create both exit 0 with an error sentence.
- One reply judge for the whole shell. A dispatch never discards its reply.
- A Lua-config session and a classic-config session answer the same command differently. A dispatch that only works on one carries the fallback for the other or fails with a diagnostic.

## QML

- `FolderListModel` treats a missing folder as the process working directory and reports the swap through its `folder` property. Compare `folder` with the folder asked for before reading the listing.
- `Process.exited` fires before `running` becomes false. A command that fails to start emits no `exited`.
- `Qt.resolvedUrl()` gives asset URLs. `Quickshell.shellDir` gives the filesystem path a subprocess needs.
- Console output from a standalone `qml6` probe prints nothing on the reference machine. A probe returns its result through its exit code.

## Validation

- The nested compositor sandbox needs `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` in the environment. An agent shell without them fails the row before the shell starts.
- The nested smoke flakes under machine load with unreadable `hyprctl` output. Run it once more before calling it a failure.
- A latency row samples shell event latency percentiles in the sandbox and asserts them against a budget the same row measured on main.
- Every figure written into a document or a budget was measured in that PR, and the text says how.
