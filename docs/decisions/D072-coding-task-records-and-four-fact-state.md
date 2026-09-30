# D072: Coding-task records preserve four independent facts

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: [Jarvis plan § Coding-task delegation](../plans/v2-jarvis-plan.md#7-coding-task-delegation), [review disposition § 13](../plans/v2-jarvis-plan-review.md#13-review-dispositions)

**Refines**: [D033](D033-floating-tuis-are-core.md), [D052](D052-automations-engine.md)

**Context**: A coding agent can end a turn while it waits for a question or permission. A successful process exit does not report whether the requested work succeeded. Coding tasks can outlive the shell and the plugin snapshot.

**Decision**: `Tasks.js` owns the record format and derives task state from independent process, turn, wait and reported-outcome facts. `task-event` writes normalized records under one file lock. The daemon validates disk records before publishing ready. The producer runs through Node from a content-addressed data copy, not a plugin snapshot. [jarvis-tasks.md](../architecture/jarvis-tasks.md) defines the ownership boundary.

**Rationale**:
- A Stop changes the turn fact, not the question or permission fact. A turn failure remains until the producer reports a new working turn.
- Only the agent's explicit outcome report supplies reported success. Neither Stop nor exit code zero supplies it.
- Whole-file rename publishes each record without a partial read. A separate dropped-event marker preserves overflow evidence without exceeding the event ceiling.
- Replay from disk removes dependence on the daemon's previous memory. The writer lock releases on process death.
- The data copy follows D052's engine lifetime. [D014](D014-source-revisions-are-published-snapshots.md) permits deletion of a task's original plugin snapshot.

**Alternatives considered**: One stored task state loses the distinction between a finished turn and a reported outcome. Agent-log or terminal parsing duplicates vendor state logic. A daemon-only event writer loses hooks while the shell is down.

**Control boundary**: J53 owns launching the agent, checking process-group identity and liveness, interruption, escalation and confirmation that the group is empty. Records confer no control authority. Claude and Codex profiles own vendor hook translation and prompt responses. Voice owns the words the user hears.

**Omarchy comparison**: The read-only Omarchy reference's `shell/plugins/agents/Agent.qml` reads collector records. `bin/omarchy-agent-usage-update` validates collector output and replaces each record by rename. VGS keeps that producer/display separation and whole-record publication. Usage records do not distinguish coding-task turns, waits and outcomes. VGS rejects parse failures before ready instead of clearing a display record.

**Revisit When**: A vendor supplies a durable task-record interface, a task requires more retained evidence than the plan permits, or the process-control owner changes.

**Verification**: `scripts/test-jarvis-tasks.js`, `scripts/test-task-event.js` and `scripts/test-jarvis-daemon.js` exercise the real record owner, copied producer and startup consumer with must-fail controls. `scripts/smoke/rows/read-only-prefix.sh` checks the installed producer from a non-writable tree.

**References**: [D033](D033-floating-tuis-are-core.md), [D052](D052-automations-engine.md), [D064](D064-jarvis-child-lease.md)
