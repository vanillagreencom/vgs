# Jarvis desktop tools

Covers: shell/plugins/vgs.jarvis/backend/Desktop.js, shell/Commons/DesktopLaunch.js, scripts/test-desktop-launch.js, shell/plugins/vgs.jarvis/backend/ShellRequests.js, scripts/test-jarvis-desktop.js, scripts/test-jarvis-requests.js, scripts/fixtures/jarvis/desktop.js, scripts/fixtures/jarvis/desktop-driver.js, scripts/smoke/rows/jarvis-desktop.sh

The [Jarvis plan § 6](../plans/v2-jarvis-plan.md#6-computer-use-and-browser-reference-set) defines the window, workspace and application tools. [The router](jarvis-approval.md) proposes each call after [Policy](jarvis-policy.md) and [Audit](jarvis-audit.md). This file defines the executors behind those calls and the request wire they use.

## Owners

- `Desktop.js::create` owns four executor records: `windows`, `compositor`, `apps` and `wire`. They share one Hyprland reader, one read-back judge and one lifetime.
- `Desktop.js::install` registers `wire` at once. It registers `windows`, `compositor` and `apps` only after one Hyprland state read answers. That read is the probe that proves `hyprctl` reaches this session. Without it the router offers none of their tools.
- `ShellRequests.js::create` owns the daemon's side of the request wire: request ids, the pending bound and reply matching. `JarvisProtocol.accept` judges every message on both sides.
- `Service.qml::serve` answers each request from one handler table keyed by kind. Each handler calls the capability that owns the act: `shell.compositor`, `shell.run.detached`, `shell.toasts` or Quickshell's `DesktopEntries`. The compositor handlers come from the `compositor.` kinds of `JarvisProtocol.REQUESTS`. The reply carries that capability's own answer. The service reads no effect back.
- `JarvisProtocol.lockedRefusal` is the service's lock rule. A request that changes the desktop (`acts` in `REQUESTS`: every `compositor.` kind, `run.detached` and `desktop.launch`) answers `refused: locked` while the service observes the session locked. Policy judged the lock when the action started; this stops the steps that remain after a later lock.
- `shell/Commons/DesktopLaunch.js` is the one launch rule, shared with the launcher: `entry()` for a desktop entry and `open()` for a file or link.
- The daemon never runs `hyprctl dispatch`. Every change is a request, so `shell/Core/Dispatch.js` stays the one dispatch judge.

The daemon's lease closes `Desktop` and `ShellRequests` after the router. A read in flight is killed, a poll starts no new read, and no request deadline holds the process.

## Tools

`Tools.TABLE` owns each row's arguments, effect and executor. Window titles and application names are `desktop` items for the [release gate](jarvis-release.md).

| Tool | Requests | Read back as completed | Not seen |
|---|---|---|---|
| `windows.list`, `workspaces.list` | none | the reply itself | |
| `windows.focus` | `focusWindow` | the target is the active window | failed |
| `windows.reveal` | `reveal` | the target is the active window | failed |
| `windows.move` | `moveWindow` | the target is at the requested point | failed |
| `windows.resize` | `resizeWindow` | the target has the requested size | failed |
| `windows.fullscreen` | `focusWindow`, then `fullscreenWindow` | the target is active, then its mode bit matches | failed |
| `windows.float` | `floatWindow` | the target's floating state matches | failed |
| `windows.workspace` | `moveWindowToWorkspace` | the target is on the workspace | failed |
| `windows.close` | `closeWindow` | the target is absent | unknown |
| `windows.monitor` | `focusMonitor` | the named monitor is focused | failed |
| `workspaces.focus` | `focusWorkspace` | the focused monitor shows the workspace | failed |
| `workspaces.special` | `toggleSpecialWorkspace` | the focused monitor's special workspace flipped | failed |
| `apps.list` | `desktop.list` | the reply itself | |
| `apps.launch` | `desktop.launch` | a new mapped window of the entry | unknown |
| `apps.open`, `apps.url` | `run.detached` of `gio open` | any new mapped window | unknown |
| `notify.toast` | `toast` | the service's `ok` reply: the core took the toast, which can wait in its queue | |

- A target window or monitor that is absent before the call fails without a request.
- `windows.monitor` accepts an output name or numeric id and sends the output name. A selector such as `+1` names no single expected monitor, so it fails before a request.
- Fullscreen acts on the focused window in both Hyprland dialects ([runtime-hyprland.md](runtime-hyprland.md)). The executor focuses the target and reads that focus back first. A focus that does not appear sends no fullscreen request.
- `set` and `unset` keep an already matching state, as the dispatchers do, and complete at once. `toggle` expects the opposite of the state read before the request.
- An application can keep its window open, for example to ask about unsaved work. A window still open after `windows.close` is therefore `unknown`, not a failure.
- Workspaces are positive integer ids. A name or relative selector has no single expected workspace for the read-back.
- `apps.list` takes an optional `query`, matched against the id or name without case. A desktop with hundreds of entries otherwise passes the router's 16 KiB result bound.

## Read-back judge

`settle(judge, deadline)` in `Desktop.js` is the one read-back for every changing tool. It polls one Hyprland state read until the judge sees the effect or the deadline passes. Each verdict also names what Hyprland showed, and that text becomes the brain's result either way.

- The state read is `hyprctl --batch` of `Dispatch.REVEAL_STATE_REQUEST`, parsed by `Dispatch.revealState`; the workspace list reads `Dispatch.WORKSPACE_STATE_REQUEST` through `Dispatch.workspaceState`. Both parsers use `Dispatch.jsonReplies`, so the batch requests, their split and each reply's top-level shape have one reader. The daemon loads `Dispatch.js` from the VGS tree through `bin/lib/qml-library.js`. The expectations in `Desktop.js` read the client and monitor fields themselves.
- The outcome is `completed` only when the judge sees the effect. A dispatcher that answers `ok` and moves nothing ends `failed`, or `unknown` for close and launch.
- A reply refused by the shell ends `failed` with the shell's answer. A request with no reply before its deadline ends `unknown`, because the shell may still act on it. A state read that fails after a request ends `unknown`.

| Bound | Value | Meaning |
|---|---|---|
| `hyprctlMs` | 2000 | one `hyprctl` read |
| `hyprctlBytes` | 1 MiB | one read's output; more fails the read |
| `requestMs` | 2000 | one service reply |
| `settleMs` | 2000 | one compositor effect |
| `launchMs` | 10000 | a launched or opened window |
| `pollMs` | 100 | the wait between reads |
| `slackMs` | 1000 | scheduling slack added to each `timeoutMs` |

These are recovery rules for a compositor or service that does not answer, not measured latency budgets. Each executor's `timeoutMs` is the sum of the bounds its longest path can spend, plus `slackMs`. A settle's last read can start just before its deadline and take a whole `hyprctlMs`, so each settle counts one. Session's own limit therefore never ends a call the executor can still answer. No executor is cancellable: a sent dispatch or launch cannot be taken back.

`hyprctl` receives only `PATH`, `XDG_RUNTIME_DIR`, `HYPRLAND_INSTANCE_SIGNATURE` and `LANG`. The service passes the signature to the daemon for that purpose.

## Request wire

The plan's [§ 3.3](../plans/v2-jarvis-plan.md#33-the-wire-between-shell-and-daemon) names the `request` and `reply` types. `JarvisProtocol.REQUESTS` is the closed kind table. Each kind lists its argument types and its reply data shape. The compositor kinds carry the dispatcher's arguments; the core's argument check still judges their values.

- `request` is daemon to shell: `{v, type, gen, revision, id, kind, args}`. `id` is a positive integer assigned in order. Text holds 1 to 4096 characters without NUL. A command holds 1 to 64 such words. [Task display](jarvis-task-control.md#display) shares this owner: `tui.run` holds one absolute spec path and opens only `task`.
- `reply` is shell to daemon: `{v, type, gen, revision, id, kind, answer, data}`. `answer` is `ok` or the capability's refusal, one printable line of at most 300 characters. `data` is `null` unless the answer is `ok` and the kind returns data.
- `desktop.list` data holds at most 512 entries `{id, name, startupClass}`, sorted by id, and `complete`. The service stops adding entries at 192 KiB, so the reply stays under the 256 KiB line bound. `desktop.launch` data is the launched entry `{id, name, startupClass, terminal}`.
- `JarvisProtocol.desktopEntries`, `desktopEntry` and `answer` build those values in the service, so the service never writes a reply the judge refuses.

At most 16 requests await a reply. The next is refused `busy` and never written. A request whose deadline passed still awaits its reply and still counts, because the service has not answered it. Its late reply is dropped. A reply for an id that awaits none, a second reply, or a reply of another kind is a protocol error: the daemon exits 65 and the service restarts it. The service answers each request it receives exactly once, so any of those replies means a broken peer.

## Applications

The service reads desktop entries through Quickshell's `DesktopEntries`, the launcher's source, so VGS keeps one entry parser. The [Quickshell 0.3.1 DesktopEntry reference](https://quickshell.org/docs/v0.3.1/types/Quickshell/DesktopEntry/) defines `command` as the parsed Exec without terminal handling and `startupClass` as the class the application intends to use. A node parser in the daemon would be a second parser with its own field-code rules.

`shell/Commons/DesktopLaunch.js` owns the launch rule for both plugins. `entry()` runs a terminal entry through `xdg-terminal-exec` and every other entry's command; `open()` runs `gio open`. `shell/plugins/vgs.launcher/Launcher.qml::launchApp` and the launcher's file actions call it. For `apps.launch` the daemon sends `desktop.launch` with the id: the service resolves the entry, runs `DesktopLaunch.entry` through `shell.run.detached` and answers the entry the read-back needs. For `apps.open` and `apps.url` the daemon loads the same file and sends `run.detached` of `DesktopLaunch.open`. `shell.run.detached` answers once the program is handed over.

The read-back accepts a new mapped window whose class or initial class equals the entry's `startupClass` or id, ignoring case. A terminal entry's window carries the terminal's class, so any new window counts there. `gio open` names no class, so any new window counts. No window within `launchMs` is `unknown`, with a sentence saying the program may still be starting, run without a window, or have opened in an existing window. A web link opened as a tab is the common case.

The service reads `DesktopEntries` once at load, which starts Quickshell's index scan before the first list request. Quickshell adds an entry planted later when its directory watch reports it.

## Requirements and policy

- `hyprctl` ships with Hyprland, the only compositor ([D001](../decisions/D001-hyprland-only.md)). It has no requirement row, as `vgs.lock`'s own `hyprctl` read has none. A failed probe leaves the Hyprland tools unoffered.
- `gio` is an optional requirement: `glib2` for pacman and dnf, `libglib2.0-bin` for apt, each checked against its package index. Without it `apps.open` and `apps.url` are unoffered. `xdg-terminal-exec` is already a core requirement.
- The manifest names capabilities `compositor` and `run` for the service's request handler.
- Policy refuses every call while locked. `apps.open` judges its path with the `read` role, so a protected path refuses. An opened file runs its default handler, which the user's MIME settings choose.
- The plan's `backend/skills/computer/windows.md` and `apps.md` are not shipped. Their `help` topic has no registered executor, and `offer()` already hands the brain each row's sentence and schema.

## Omarchy comparison

Omarchy's `bin/omarchy-launch-or-focus` (basecamp/omarchy `c05d901`) reads `hyprctl clients -j`, focuses a window whose class or title matches, else launches the command with `setsid`. Its shell's `services/AppLibrary.qml` launches through `gtk-launch` and closes its launch feedback when the toplevel count or the active toplevel changes, with a 15 s timeout. Neither reports whether the launch worked.

VGS keeps Omarchy's `hyprctl -j` read and its watch for a new window. It differs in three ways. It launches through the one launch rule the launcher also calls, `shell/Commons/DesktopLaunch.js`, rather than a second launch path. It matches the new window to the entry's class, because the result tells the brain what happened. It reports a launch with no window as unknown, not done.

## Evidence

- `scripts/test-jarvis-desktop.js` runs every executor in the [J09 world](validation-jarvis.md) against a stand-in `hyprctl` and a fake shell side that moves synthetic Hyprland state. Its table covers each tool's effect, a dropped dispatch, a refusal, a silent shell, a failed read, absent targets, launches with and without a matching window, a terminal entry, `gio open`, the service's lock refusal and toasts. Two rows run the longest compositor and launch paths near their bounds, with slow stand-in reads and slow replies, and assert each ends inside `timeoutMs`. It pins each read's argv and environment, a removed stand-in, probe-first registration and no read after close. Controls remove the read-back wait, the close outcome, the fullscreen focus step, the toggle's prior state, the target and monitor checks, the refusal, timeout and unread outcomes, the class match, the terminal window match, the new-window check, the list query, probe-first registration, the closed reader, the second settle of the compositor bound and the last read of the launch bound.
- `scripts/test-desktop-launch.js` pins `DesktopLaunch.js`, with a control that drops the terminal rule and one that changes the opener. `scripts/test-dispatch.js` pins `jsonReplies` through both state parsers.
- `scripts/test-jarvis-requests.js` pins the pending bound, a timed-out request's slot, the late reply drop, unknown, repeated and mismatched replies, writer refusal and close. A control removes each rule.
- `scripts/test-jarvis-protocol.js` pins the request and reply shapes, the kind table, the entry builders and the lock rule per kind, with a control per guard. `scripts/test-jarvis-daemon.js` proves a reply before hello or for an unsent request exits 65, and that the probe's `hyprctl` sees only its four variables. It also pins the disposable desktop driver's result delivery after the engine and scripted ports are installed. A control installs that driver too early and loses the result.
- `scripts/smoke/rows/jarvis-desktop.sh` drives a disposable daemon through `scripts/fixtures/jarvis/desktop-driver.js`, which routes each call through the real router, Policy, Audit, executors, wire and service. The daemon's `hyprctl` stand-in is pinned to the nested instance and refuses a dispatch. The row reads each effect from the nested Hyprland itself: focus, float, move, resize, fullscreen, workspace moves and focus, reveal, special workspaces, monitor focus, a planted entry's launch, close and a toast. A shell `hyprctl` that answers `ok` without dispatching must not report completed; a planted read-back that never waits fails that assertion once. J09 gives the daemon no session identifier, so the row reads the signature the service hands its launcher from `/proc`; a service copy that drops it fails that reading once.
