# D045: TUI wait holds a per-run lock

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: VGS-590: VGS-586 nested smoke, round 1

**Refines**: [D043](D043-tui-run-ends-by-lock-release.md)

**Context**: [D043](D043-tui-run-ends-by-lock-release.md) made `vgsh-tui wait` block on the key lock, `<stem>.lock`, and then read the run's records. The next presenter of the same key takes that lock with `flock -n` as soon as the first presenter releases it, and nothing orders a blocked waiter ahead of it. That presenter removes the earlier run's running record when it starts and its ended record when it ends. A waiter that reads after that finds no record, exits 1 `reason=gone`, and the shell logged it as `tui: wait=<key> run=<run> reason=failed`. The VGS-586 nested smoke logged that line in round 1 for two quick runs of `vgs.devtools/install`, and a rerun passed. The shell cannot launch the next run of a key before it has read the earlier run's ended record, so that wait was no longer needed: its end is not a failure.

**Decision**: Each run has its own lock, `<stem>@<run>.lock`. `present` holds the key lock as before, removes the lock names of earlier runs of the key, takes the run lock with `flock -n` before it writes the running record, and removes the run lock's name after it writes the ended record. `wait` blocks on the run lock only. It then prints the ended record. With only the running record left, it takes the key lock, reads the records again under it, and ends the run with a null code as before. With neither record, a later run of the key removed them after the run ended, and `wait` exits 3, `reason=gone`, a code no other refusal uses. `reap` removes the run lock's name of a run it ends or whose running record it removes. `PluginLogic.tuiWaitOutcome` takes the runs the core still awaits, `tuiWaitRuns` as the wait finished, and matches the wait by key and run: a gone run no longer awaited logs nothing, a gone run still awaited logs `reason=gone`, and every other end logs as before.

**Rationale**:

- A later run of the key holds the key lock and never the run lock, so it cannot delay an earlier run's wait.
- The gone code tells an obsolete wait apart from a real failure without a second channel, and the shell decides by run id against the runs it awaits, because by then the key's slot may already name the next run.
- A run id is new, and the core starts a wait only once the running record exists, so no process holds the run lock when the presenter takes it. `flock -n` turns a held run lock into a refusal instead of a deadlock with a waiter that holds it and waits on the key lock.
- A presenter's run lock name goes with its ended record, and a waiter's with its read, so the directory holds no run lock once a run and its wait end. Names a killed waiter leaves are removed by the next run of the key.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Keep the earlier run's ended record until the shell has read it | The presenter cannot know what the shell read, and a key's records would then grow with no owner to remove them. |
| Let the waiter queue ahead of the next presenter on the key lock | `flock` has no fair queue: a stopped or slow waiter still loses to a presenter that asks later. |
| Keep exit 1 and filter the log line in the shell by its text | The judgement would rest on stderr prose, and a real `gone` for a run the core still awaits would be hidden with the obsolete one. |

**Revisit When**: The presenter stops removing earlier runs' records, or the core stops holding a key busy until it has read the earlier run's end.

**Verification**: `scripts/test-vgsh-tui.sh` runs back-to-back runs of one key 50 times with the wait held by SIGSTOP, so the order is fixed: a wait that reads after the next run ended exits 3, and a wait that reads while the next run still runs prints its own run's ended record within the 1000 ms ceiling. Controls wait on the key lock, which stays blocked past the ceiling, and exit 1 for a gone run. `scripts/test-tui-logic.js` pins which gone ends log, with controls that match by key alone, drop the line and log every gone end. `scripts/qml-tests/tst_tui_records.qml` finishes an obsolete wait with the gone code after the next run started and checks that no second `done` fires and the next run's wait stays live.

**References**: [D043](D043-tui-run-ends-by-lock-release.md), [tui-records.md](../architecture/tui-records.md), [tui.md](../architecture/tui.md)
