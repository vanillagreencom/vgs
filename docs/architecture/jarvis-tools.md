# Jarvis desktop tools

Covers: shell/plugins/vgs.jarvis/backend/Executors.js, shell/plugins/vgs.jarvis/backend/Desktop.js, shell/plugins/vgs.jarvis/backend/Child.js, scripts/test-jarvis-desktop-tools.js, scripts/test-jarvis-child.js, scripts/fixtures/jarvis/desktop-tool.py, scripts/qml-tests/tst_jarvis_service.qml

The clipboard, media and notify executors run the J46 rows of `Tools.TABLE`. [The router](jarvis-approval.md) still owns policy, approval, audit and the result label. The [chained engine](jarvis-engine.md) uses the router's offers and returns routed results to the brain.

## Owners

- `Executors.register` is the daemon's one registration seam. It installs the shared [window and application owner](jarvis-desktop-tools.md) through `DesktopSession.install`, then each command executor of its `OWNERS` table through `Desktop.create`, then the [vision executor](jarvis-vision.md) through `Vision.install` on the session's Hyprland reader. It returns the installed lifetimes for teardown after the router closes.
- `Desktop.create` builds the `clipboard`, `media` and `notify` executors. Its `ARGV` table is the one map from a frozen call to a command's arguments and stdin. The command name comes from the call's Tools row. `Desktop.runCommand` runs one such command as [Commands](#commands) states; the vision executor runs its commands through it too.
- `Child.run` owns one bounded child: no shell, a whole explicit environment, a deadline, one byte ceiling over stdout and stderr, cancellation and one end. [The kernel sandbox](jarvis-sandbox.md) and the desktop executors both use it. The sandbox ends bwrap alone, whose die-with-parent ends the namespace. A desktop child leads its own session and process group, and its end kills that group.
- `notify.toast` uses the registered `wire` executor and [daemon-to-shell request wire](jarvis-desktop-tools.md#request-wire). It stays offered even when Hyprland cannot answer the window owner's probe.
- `media.brightness` is not offered. [D083](../decisions/D083-brightness-helper-and-uaccess-rule.md) makes `vgs.displays` the one brightness owner, so Jarvis will route the row through its brightness service once System S16 exposes it. `ARGV` has no entry for it, so the seam never looks up `brightnessctl`. The row keeps its schema, from 1 to 100, as the reserved call contract that route uses.

## Registration

On the first hello, the daemon passes its router, `commandFile` from `bin/lib/judge-files.js`, its own environment and the desktop installation options to the seam. `commandFile` is the shared PATH lookup: the first executable regular file in an absolute PATH directory. For command executors the seam looks up each command the executor's Tools rows declare and runs none of them. It registers the executor with the commands found and their absolute files. An executor none of whose rows can run registers nothing. The router's `offer()` already drops a row whose command is absent. A command installed later appears at the daemon's next start. The shared desktop owner retains its own Hyprland probe and lifetime.

`Service.qml` gives the daemon `WAYLAND_DISPLAY` and `DBUS_SESSION_BUS_ADDRESS` beside its other variables. The daemon passes them only to the commands below, the [vision commands](jarvis-vision.md#owners) and the [input executors' transport](jarvis-input.md). `scripts/qml-tests/tst_jarvis_service.qml` pins the daemon's whole environment.

## Commands

Each command runs as `setpriv --pdeathsig KILL -- <file> <argv>`, `<file>` the absolute path the lookup found. setpriv execs the command, so the command keeps its process id and leads its group. A daemon killed outright takes the running command with it. The kernel clears that signal across fork, so the server wl-copy forks keeps the selection.

| Tool | Argv | Stdin |
|---|---|---|
| `clipboard.read` | `wl-paste --list-types`, then `wl-paste --no-newline --type text` | none |
| `clipboard.write` | `wl-copy --type text/plain;charset=utf-8` | the text |
| `media.play`, `media.pause`, `media.next` | `playerctl play`, `playerctl pause`, `playerctl next` | none |
| `media.volume` | `wpctl set-volume @DEFAULT_AUDIO_SINK@ <value>`, value with two decimals | none |
| `media.mute` | `wpctl set-mute @DEFAULT_AUDIO_SINK@ 1` or `0` | none |
| `notify.notification` | `notify-send --app-name=Jarvis -- <title> <body>` | none |

- The volume number uses the C.UTF-8 locale, so its decimal mark is always a point. The Tools schema bounds it to 0 through 1, so no `--limit` repeats that rule.
- After `--`, notify-send's GLib option parser reads no option, so model text stays positional.
- wl-copy receives an explicit type, so it runs no `xdg-mime`.

| Command | Variables beside `PATH` and `LC_ALL=C.UTF-8` |
|---|---|
| `wl-paste`, `wl-copy` | `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` |
| `playerctl`, `notify-send` | `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR` |
| `wpctl` | `XDG_RUNTIME_DIR` |
| `grim`, `slurp` | `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` |
| `magick`, `tesseract` | none; the [vision executor](jarvis-vision.md#owners) gives `magick` `MAGICK_TEMPORARY_PATH` |

No other daemon variable reaches a child: no key, no `VGSH_RUNNER_PID`.

## Clipboard

- A read lists the offered types first. An offer of `x-kde-passwordManagerHint` refuses as `clipboard-password`. An offer without `text/*`, `UTF8_STRING` or `STRING` refuses as `clipboard-not-text`. Neither refusal reads a clipboard byte. A password that no password manager marks is read like any other text.
- An empty clipboard completes with empty text. wl-paste reports one as exit 1 with the first stderr line `Nothing is copied` (wl-clipboard 2.3.0 `src/wl-paste.c`), or as an empty type list.
- A read past the output ceiling completes with the text kept. The router cuts every result to its own smaller bound and marks the cut.
- The result reaches the brain port as an item labelled `clipboard`. [Release](jarvis-release.md) then asks before it goes to a network recipient set in `standard` or `cautious`, unless a grant covers it.
- A write sends the text through stdin, because argv is readable in `/proc`. wl-copy forks a server that keeps serving the selection after wl-copy exits. The server stays in wl-copy's process group: wl-copy 2.3.0 imports `fork` but neither `setsid` nor `setpgid`. A success never signals that group. A timeout or cancellation kills the group, server included. wl-copy's stdout and stderr go to `/dev/null`, so a server that keeps them cannot hold the call open.

## Bounds and outcomes

The output ceiling is the [plan's command bound](../plans/v2-jarvis-plan.md#311-bounds), 64 KiB. A child ends after 10 s, and Session's tool limit is 12 s, so the child's own end reports first. These are recovery bounds for a compositor, bus or daemon that never answers, not measured latencies.

| Child result | Outcome | Content |
|---|---|---|
| exit 0 | `completed` | the clipboard text for a read, else `{"kind":"done"}` |
| nonzero exit | `failed` | `{"kind":"failed","command","code","detail"}`, detail the first stderr line |
| killed by another signal | `failed` for a read, else `unknown` | `{"kind":"failed","command","signal"}` |
| ended by deadline, cancellation or ceiling | `failed` for a read, else `unknown` | `{"kind":"stopped","command","reason"}` |
| not started | `failed` | `{"kind":"failed","command","reason","error"}` |
| refusal | `failed` | `{"kind":"refuse","reason"}` |

An empty clipboard and a read past the ceiling complete instead, as [Clipboard](#clipboard) states. A stopped command may already have acted, so only a read reports a plain failure. Session's stop, expiry and lease end each cancel a running command through the router, which kills its group. The daemon's teardown therefore needs no second owner of these children. setpriv's parent-death signal covers a daemon killed outright.

## Evidence

- `scripts/test-jarvis-desktop-tools.js` runs the real seam, router, Session, Policy and Audit in the [J09 world](validation-jarvis.md). Stand-ins under each command name record argv, stdin, environment, process id, parent, group and parent-death signal. It pins every argv above, each child's whole environment, its own process group and the KILL parent-death signal. It covers the password, non-text and empty clipboard cases, failure detail, the ceiling, the deadline, cancellation, wl-copy's server, without that signal, surviving success and dying with its group on timeout. A probe table proves a missing command removes only its rows, an executor with no command registers nothing, and the lookup runs no command. In every probe row `media.brightness` is absent from `offer()` and its route refuses `executor-unavailable`, even with a `brightnessctl` on PATH.
- The release case reads the item the brain port receives. `Policy.release` answers `ask` with a marker and no clipboard bytes for network recipients in `standard` and `cautious`, and `send` offline, in `trusted` and with a matching grant.
- Its controls edit disposable copies: argv, the `--` separator, stdin moved to argv, a leaked environment, the hint and non-text refusals, empty-selection classification, ceiling, deadline, outcome, process group, parent-death signal, wl-copy output, cancel, a brightness entry put back, an absent command accepted, an executor with no command registered, and a `desktop` or missing label on `clipboard.read`.
- `scripts/test-jarvis-daemon.js` runs the shipped seam in a disposable daemon copy that changes only its brain port. One routed `media.play` reaches the playerctl stand-in and its result reaches the brain port. A held command dies when the daemon's stdin ends. Its controls drop the register call and the router's cancel.
- Passing cases use the production deadline. Only a control whose broken copy never ends its child gets a 2 s bound.
- `scripts/test-jarvis-child.js` covers `Child.run` alone: exact environment, stdin, the shared ceiling with replacement characters, deadline, group end, ignored output with a surviving server, cancellation and spawn failure. A control removes each rule.
- [Validation](validation.md) selects both suites on the seam, executors, child owner, router, Policy, Session, the shared PATH lookup and their fixtures. The sandbox row also selects on the child owner, and the audio daemon row on every file the daemon loads for the seam. `scripts/test-validate.sh` pins those plans and controls each audio daemon edge.
- No smoke row: J46 adds no surface, service or plugin. The desktop tool suite uses stand-ins for the commands that act outside Jarvis.

## Omarchy comparison

- Omarchy's clipboard capture skips a copy that offers `x-kde-passwordManagerHint` and treats the same offers as text. VGS takes both rules.
- Omarchy's notification sender calls `Notify` through busctl so a headline cannot become a notify-send option. VGS keeps notify-send, the plan's command, and ends its options with `--`.
- Omarchy's volume keys resolve a filter sink to its physical sink through pactl. VGS sets `@DEFAULT_AUDIO_SINK@` through wpctl, the plan's command, with no second resolver.
