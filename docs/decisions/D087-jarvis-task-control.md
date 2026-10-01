# D087: Coding tasks are controlled by a recorded process group, apart from their display

[← Decision Index](INDEX.md)

**Date**: 2026-10-01
**Status**: Active
**Research**: [Jarvis plan § Coding-task delegation](../plans/v2-jarvis-plan.md#7-coding-task-delegation), [review finding 12](../plans/v2-jarvis-plan-review.md#13-review-dispositions)
**Refines**: [D072](D072-coding-task-records-and-four-fact-state.md), [D033](D033-floating-tuis-are-core.md)

**Context**: A coding agent runs in a terminal the user can watch: a tmux session or a floating TUI. Jarvis must stop it on request, and must never signal a process that is no longer the task's. A terminal's own process tree or window says nothing reliable about which processes belong to the agent, and a pid can be reallocated after the agent ends.

**Decision**: A launcher, `task-run.py`, runs in the terminal. It forks the agent as the leader of a new process group, holds it on a pipe, records `started { pid, pgid, sid, startTime }` through the task's producer, and only then lets it exec. `TaskRunner.js` reads that identity before every signal, escalates from the profile's interrupt to SIGTERM to SIGKILL against `-pgid`, and writes `stopped` only after `kill(-pgid, 0)` answers `ESRCH`. `stopped` is absorbing in the record. Display is a choice the setting `taskTerminal` makes: a private tmux server for any number of tasks, or the plugin's `task` floating TUI for one at a time. The launch spec travels as a private file, never as TUI arguments or typed command text. [jarvis-task-control.md](../architecture/jarvis-task-control.md) holds the contract.

**Rationale**:
- Start ticks from `/proc/<pid>/stat` with the pgid and sid distinguish the agent from a reallocated pid. The kernel does not reallocate a pid while it names a live group or session, so group members with the recorded sid that started no earlier than the leader are the task's own after the leader exits.
- Recording before exec means no agent runs without an identity a stop can verify. A failed record kills the held child.
- The empty read is the only proof a stop finished. A killed leader stays a zombie member until its parent reaps it, so a stop that writes `stopped` right after SIGKILL can claim an end that has not happened.
- The launcher, not the terminal, owns the exit record, so the tmux and floating displays give the same facts. It ignores the terminal's hangup signals long enough to record a closed window.
- The core's floating TUI keeps one busy key per TUI name across all arguments. The executor refuses a second floating start before creating a record, and maps the core's `busy` reply in a race to a refusal and a `lost` record.

**Deviations from the plan**:
- The tmux server uses `-S $XDG_RUNTIME_DIR/vgs/jarvis/tmux.sock`, not `-L vgs-jarvis`. The socket then lies in the 0700 Jarvis runtime directory, and tests reach a private server without `TMUX_TMPDIR`.
- A failed stop reaches the user as a `task-answer` message the service toasts and logs, not as a daemon stderr line, because the service treats daemon stderr as the cause of the daemon's end.
- The daemon registers no task executor until an agent profile and a release port for the conversation's recipients exist. Neither exists yet; a fake release would let a goal leave the machine without a release decision.

**Alternatives considered**: Signalling the terminal's or the tmux pane's process tree reaches the shell and the terminal, not only the agent, and gives no identity across a pid reuse. A stop that trusts SIGKILL without the empty read reports an end the kernel has not finished. Passing the goal as TUI arguments exceeds the core's argument bounds and puts the goal in a process list.

**Omarchy comparison**: Omarchy (basecamp/omarchy `c05d901`, `default/bash/fns/tmux`) starts AI agents in panes of the user's own tmux server with `send-keys`, as typed command text, with no process control or record. VGS hands the terminal an argv, leads a recorded process group and escalates a stop against it. VGS uses a private server, so a task never lands in the user's sessions and the user's server is never signalled.

**Revisit When**: A vendor agent offers a documented stop or session-control interface, Linux exposes a pidfd for a whole process group to unprivileged callers, or a task needs to run outside the user's PID namespace.

**Verification**: `scripts/test-jarvis-task-runner.js` runs the real launcher, real signals and private tmux with controls for the empty read, the identity check and the one-at-a-time rule. `scripts/test-jarvis-daemon.js` runs startup observation and the `task-stop` intent end to end. `scripts/smoke/rows/jarvis-tasks.sh` proves the service half against the real core.

**References**: [D072](D072-coding-task-records-and-four-fact-state.md), [D033](D033-floating-tuis-are-core.md), [D064](D064-jarvis-child-lease.md), [D082](D082-jarvis-approval-bound-to-the-action.md)
