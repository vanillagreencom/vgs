# Jarvis coding-task control

Covers: shell/plugins/vgs.jarvis/backend/TaskRunner.js, shell/plugins/vgs.jarvis/backend/AgentProfiles.js, shell/plugins/vgs.jarvis/backend/task-run.py, shell/plugins/vgs.jarvis/tui/task.sh, scripts/test-jarvis-task-runner.js, scripts/fixtures/jarvis/task-agent.py, scripts/smoke/rows/jarvis-tasks.sh

This file holds how Jarvis launches a coding agent, judges which processes belong to a task, stops them and shows them. [jarvis-tasks.md](jarvis-tasks.md) owns the records this control writes. [D087](../decisions/D087-jarvis-task-control.md) records the choice. The [Jarvis plan § Coding-task delegation](../plans/v2-jarvis-plan.md#7-coding-task-delegation) sets the scope: control is separate from display.

## Owners

| Owner | Does |
|---|---|
| `AgentProfiles.js` | The profile row contract and its validation, the goal brief and the agent's explicit environment. Production ships an empty table |
| `TaskRunner.js` | The router's `task` executor and the controller: launch, identity checks, observation, stop escalation, the floating one-at-a-time rule and the live-task count |
| `task-run.py` | The launcher the terminal runs: the process-group leader, the `started` and `exited` records |
| `tui/task.sh` | The plugin's `task` floating TUI. It runs the launcher with the spec path as its one argument |
| `jarvisd.js` | Creates the controller after task-store recovery and routes `task-stop` and `tui-state`; `ShellRequests.js` owns task and desktop requests together |
| `Service.qml` | Opens the `task` TUI for a daemon request, forwards its run state, writes the `tasks` count and toasts a failed stop |

Every record goes through the task's recorded producer, `node ENGINE --state STATE ID KIND` with JSON on stdin. Neither module calls a `Tasks.Store` writer. Engine and tmux children run asynchronously; the daemon's event loop runs no `spawnSync` for a task.

## Launch

The executor is `register("task", { start, timeoutMs: 20000, cancellable: false, commands: [] })`. The timeout bounds the launch only. `start` resolves these in order and refuses before any record:

1. The agent: `args.agent`, else the first profile whose program is on PATH. An unknown or absent agent is `task-agent-unavailable`.
2. The account: an account for a row with no account variable is `task-account-unsupported`.
3. The terminal: setting `taskTerminal`. `auto` is tmux when `tmux` is on PATH, else floating. `tmux` without tmux is `task-tmux-missing`. A floating start while the TUI runs or before the service reported the TUI is `task-floating-display-busy`. The router runs one action at a time, so no second start overlaps a launch.
4. The release: `release(goal, agent, account)` must answer `send`, else `task-release-refused`.

Then `start` creates the record through the current engine, writes the spec and opens the terminal. A launch that fails after creation removes the spec and writes `lost`: a tmux failure is `task-tmux-failed`, the core's `busy` answer is `task-floating-display-busy`, and any other refusal is `task-floating-launch-refused`. Success answers `{ task, terminal }`.

The daemon registers no executor. A task needs an agent profile, which the Claude Code and Codex issues add, and a release port for the conversation's recipients, which the conversation owner adds. Neither exists, so the daemon only observes and stops recorded tasks.

### The spec

The daemon writes `$XDG_RUNTIME_DIR/vgs/jarvis/tasks/<id>.json`, directory 0700, file 0600, whole and renamed. It holds `{ v, id, state, engine, cwd, argv, env }`. `argv` is the profile's list, never a command line. `env` holds `PATH`, `HOME`, `LANG` and the XDG directories from the daemon's environment, plus the profile's account variable when an account is selected. It carries no key and no `VGSH_RUNNER_PID`. The launcher adds only `TERM` and `COLORTERM` from its terminal.

The launcher opens the spec with `O_NOFOLLOW`, requires a private regular file of its own user, reads at most 64 KiB, unlinks it, then judges its exact shape. A spec launches at most once.

### The brief

`AgentProfiles.brief` gives every agent the user's goal, then a last step: run one of two printed commands. Each pipes `{"kind":"reported-ok"}` or `{"kind":"reported-failed"}` to the recorded producer's `outcome` kind. Every path is single-quoted, so a state directory with a quote, a space or `$(...)` reaches the producer intact. The goal is text inside the brief, never shell code.

### The launcher

`task-run.py` ignores SIGHUP, SIGINT and SIGQUIT, so it outlives a closed terminal long enough to record the exit. It forks. The child calls `setpgid(0, 0)`, restores default signal dispositions and blocks on a pipe. The parent calls `setpgid(pid, pid)`, makes the child's group the terminal's foreground group when stdin is a TTY, with SIGTTOU ignored, and reads `/proc/<pid>/stat` after its last `)`: pgid, sid and the start ticks of field 22. It records `started { pid, pgid, sid, startTime }` and only then releases the child to `execvpe`. A failed `started` kills the held child, which never execs, and exits 74. An exec failure arrives over a close-on-exec pipe and ends as exit 127. The launcher waits for the leader, restores its own foreground group and records `exited { code }`, 128+N for a death by signal N. It never signals the group. It exits with the agent's code below 128 and 0 for a death by signal: a stop, a Ctrl-C or a closed terminal ends the floating window without a failure prompt that would keep the `task` TUI busy.

## Identity

A group belongs to its task when the leader's `/proc/<pid>/stat` holds the recorded start ticks, pgid and sid. A leader pid with other start ticks was reallocated, which is a mismatch. With no leader, the group still belongs to the task while it is non-empty and every member carries the recorded sid and started no earlier than the leader: the kernel does not reallocate a pid while it names a live process group or session. Anything else is a mismatch. `kill(-pgid, 0)` reads the group: `ESRCH` is empty and `EPERM` is a group of another user.

The launcher records the sid of its terminal's session. A process whose session leader lies outside its PID namespace reads sid 0, which the record refuses. A terminal starts its command in a session of its own.

## Stop

`stop(id)` answers `stopped` or a keyed refusal. One stop runs per task (`stop-in-flight`). It requires the process fact `alive`, or `exited` while members of the group remain: a leader's exit can leave background children running, and the member rule still judges them (`not-alive`, `task-unknown`). It reads identity before every signal:

1. The profile's interrupt signal to `-pgid`, SIGINT for an agent with no row, then empty reads every 50 ms for up to `interruptMs`.
2. SIGTERM, then up to 3 s.
3. SIGKILL, then up to 3 s.

`stopped` is written only after the group reads empty. A group that never empties answers `stop-incomplete` and writes nothing. A failed identity writes `lost` for an alive task, answers `identity-mismatch` and sends nothing further. A group already empty before any signal is `lost`, answered `already-ended`, or for an exited task `not-alive`. A `lost` the producer refuses as stale means the record moved; the stop reads the task again, at most three times (`task-changed`). A zombie member keeps its group non-empty until its parent reaps it. `stopped` is absorbing in `Tasks.derive`, because the launcher's own `exited` can land after the controller's empty read.

The intent `task-stop { task }` starts a stop. The service sends it from `stopTask(id)`, which the console's Stop button calls and the plugin's IPC handle `stop-task` reaches with the id as its one argument. The global Stop key does not stop tasks. The daemon answers `task-answer { task, answer }`. The service toasts an answer other than `stopped` and logs `jarvis: task-stop=<answer> task=<id>`. The service reads daemon stderr as the cause of the daemon's end, so a failed stop does not use it. A record or `/proc` failure inside a stop ends the daemon with exit 74, as an observation failure does.

## Observation

Observation writes only `lost`, compare-and-set ([jarvis-tasks.md § Facts and replay](jarvis-tasks.md#facts-and-replay)); a stale answer starts another pass. `started` is the alive fact; the controller writes no periodic `alive` event. A task is lost when its identity fails, when its group is empty with no exit recorded, and when it is still `starting` 30 s after creation. A stale spec is removed. The daemon observes every task after startup recovery, every 5 s while any task is live on an unreferenced timer, after each stop, and when the `task` TUI's run ends. It sends the live count, starting and alive tasks, as `tasks { count }` when the count changes. The service writes it to the `count` status `tasks`. Tasks outlive the daemon: EOF stops observation only, never a task.

## Display

- **tmux**: a private server on `-S $XDG_RUNTIME_DIR/vgs/jarvis/tmux.sock`, inside the Jarvis runtime directory and never the user's own server. Each task runs in one session: `new-session -d -s jarvis-<id> -c <cwd> -- python3 <backend>/task-run.py --spec <path>`. Any number of tasks run at once. tmux is an optional requirement.
- **Floating**: the daemon sends `request { id, kind: "tui.run", args: [spec] }` through the [shared request owner](jarvis-desktop-tools.md#request-wire). The service calls `shell.tui.run("task", args, done)` and answers `reply { id, kind: "tui.run", answer, data: null }` with the core's text. It forwards `shell.tui.state.task.running` as `tui-state { name: "task", running }` on each change, after each ready answer, and from `done` for a run that ended before its record said running. The controller marks the TUI busy on an `ok` reply only when no `tui-state` arrived after its request, so reports apply in message order. One TUI name is busy across all arguments ([tui-capability.md](tui-capability.md)), so one floating task runs at a time.
- Task and desktop requests share the pending bound and reply matching. A task request waits up to the executor's launch timeout. Timeout or wire refusal becomes a display refusal; the existing launch-failure path removes its spec and records `lost`. Teardown releases pending deadlines and stops observation.

## Evidence

- `scripts/test-jarvis-task-runner.js` runs in the [J09 world](validation-jarvis.md) with the real launcher, real signals, the fixture agent and tmux on a private `-S` socket. It pins `stopped` only after the group, children included, reads empty: a launcher held stopped keeps the killed leader a zombie, so a `stopped` written straight after SIGKILL finds the group present. It also pins a second floating start refused before any record, the busy reply as a refusal plus `lost`, an identity mismatch as `lost` with no signal, observation, the one-shot spec removed on failure, `exited` codes for a normal, a signal and an exec death, the brief's own report command, and two concurrent tmux tasks. It also pins a stale `lost` answered by reading again, the member rule for a gone leader and for another session, a stop of members an exited leader left, a stop and an exit past the event ceiling, reply ordering, and the launcher's 0 status for a signal death. Its controls drop each of those rules, the empty read after SIGKILL, the identity check, the one-at-a-time check, the observation identity, the brief's quoting, the spec unlink, the signal code and the held child's kill. The held launcher resumes on the first empty read after SIGKILL, not after a delay.
- `scripts/test-jarvis-tasks.js` and `scripts/test-task-event.js` pin `sid`, `stopped`, its absorption in replay and in the noisy marker, the stale `lost` refusal, and a prune met between `list` and `read`.
- `scripts/test-jarvis-protocol.js` pins every new wire type with a control per rule. `scripts/test-jarvis-daemon.js` runs startup observation and the `task-stop` intent end to end on a group the test starts, with a control for each. Its `taskWire` case proves shared request replies reach task display; its control sends the wrong request kind.
- `scripts/smoke/rows/jarvis-tasks.sh` drives the real service and core. A gated daemon fixture's request opens the shipped `task` TUI with the spec path alone, a second request gets the core's `busy`, and the run state reaches the daemon. The stand-in terminal holds the run; no task script, agent or tmux runs. The row also reads the `tasks` count from a synthetic starting record, the `stop-task` IPC handle's intent and refusal of a malformed id, and the toast for a failed stop. Each control plants one Service defect and must fail at its own step: the state forward, the spec argument, the count, the intent and the toast.

## Omarchy comparison

Omarchy (basecamp/omarchy `c05d901`, `default/bash/fns/tmux`, `bin/omarchy-launch-terminal-tmux`) starts AI agents in panes of the user's own tmux server by typing their command with `send-keys`, and keeps no process identity or record. VGS hands the terminal an argv, so no goal or path becomes typed command text. Its launcher leads a process group whose identity is recorded before the agent runs, and a stop escalates to SIGKILL against that verified group. The server is private to Jarvis, so a task never lands in the user's sessions and the user's server is never signalled.
