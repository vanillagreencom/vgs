# D053: The runner holds the instance lock and waits on the shell as its child

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: VGS-609

**Context**: `bin/vgsh run` took `flock` on `$XDG_RUNTIME_DIR/vgsh.lock` on descriptor 9 and then execed `qs`. The descriptor was not close-on-exec, so every process the shell started inherited it and held the lock after the shell had exited. On host cachy on 2026-09-29, a `/proc/<pid>/fd` scan during two nested smokes found children of the sandbox `qs`, such as `bash .../slow-download theme wallpapers --json nord`, holding the sandbox's `vgsh.lock` (VGS-605). The impact: `vgsh restart` stopped the shell, waited 10 s on the lock and refused `stop=timeout ... the shell is still running`, which was false, and started no shell, so the user had no bar until the child ended. `vgsh run` after a crash refused `another vgsh run holds the instance lock` for the same time. It needs a restart or a crash while a long child runs, such as a large theme download.

**Decision**: The runner keeps the lock and does not exec `qs`. After it takes the lock, it starts a subshell that writes its own pid as the lock file's only line through descriptor 9, closes its copy of descriptor 9, and execs `setpriv --pdeathsig TERM -- qs -p <tree>/shell` with `VGSH_RUNNER_PID` set to that pid. The runner then waits on that child and exits with its status. A trap on HUP, INT and TERM passes TERM to the shell, and the wait is repeated when a trapped signal ends it early. The contract is [runtime.md § Process](../architecture/runtime.md#process).

- **One lock holder.** Only the runner holds the lock's open file. It exits after the shell has exited, so the lock frees when the shell exits, whatever processes the shell left behind.
- **The shell's pid.** The lock file and `VGSH_RUNNER_PID` name the shell's pid, which the child writes before it execs, so the file names the shell before the shell starts. `vgsh pid`, `ipc`, `log` and `restart` read the shell's pid from the lock file, and the guard in `shell/shell.qml` compares `VGSH_RUNNER_PID` with the shell's own pid, both as before. `vgsh restart` sends TERM to that pid and waits on the lock, which frees when the runner exits after the shell.
- **The runner's death.** `setpriv` execs `qs` in the same process with TERM as its parent-death signal. A runner killed with SIGKILL, which runs no trap, takes the shell with it, so no guarded shell runs with the lock free, and "one shell per session" holds.

### The options

| Option | Taken | Rejected, and why |
|---|---|---|
| A: the runner keeps the lock and waits on `qs` as its child | Yes | |
| B: a close-on-exec lock the shell takes again | | Quickshell 0.3.1 gives QML no `flock`, so the shell would need a helper process to hold the lock, and that helper must not pass the descriptor to anything the shell starts. Between the runner's exec and the new hold, no process holds the lock, so a second `vgsh run` can start in that gap. |
| Parent-death signal | `setpriv --pdeathsig TERM` from util-linux | No parent-death signal: a runner killed with SIGKILL leaves a guarded shell with the lock free, and a second `vgsh run` starts a second guarded shell. |

**Rationale**:

- Option A is the smaller change. The pid contract stays as it was for every reader of the lock file and for the guard, because the pid the runner hands the shell is the shell's own.
- `setpriv` is in util-linux, the package that already gives `flock`. It is a new required row of `config/requirements.json`. Fedora ships `setpriv` in `util-linux`, not in `util-linux-core` (the `%files` sections of Fedora's `util-linux.spec`, read on 2026-09-29), so the Fedora recipes require both packages. Gentoo builds `setpriv` only with the `caps` USE flag of `sys-apps/util-linux`.
- A non-interactive bash starts a background job with SIGINT and SIGQUIT ignored, so the runner passes each stop signal on as TERM, never as INT.

**Consequences**:

- Each session has one more bash process, the runner, which sleeps in `wait` for the shell's life.
- The runner's pid is no longer the shell's. The nested smoke's `start_shell` keeps the runner's pid for `stop_shell` and addresses the shell by the pid the started tree's `vgsh pid` reads from the lock file.
- The parent-death signal leaves one race: a runner killed after it starts the child and before `setpriv` sets the signal leaves a shell with no parent-death signal. The gap is the time of one fork and one exec.

## Where VGS differs from Omarchy

Checked against basecamp/omarchy at `8b4eae6`: `bin/omarchy-launch-shell`, `bin/omarchy-restart-shell`.

| Omarchy | VGS | Why |
|---|---|---|
| `omarchy-launch-shell` runs `quickshell` as a background job, waits on it in a loop that tolerates a wait a signal ended, and a `trap stop HUP INT TERM` passes TERM to it. | The same: a background child, a repeated wait and TERM passed on for HUP, INT and TERM. | Taken from Omarchy. |
| The launcher keeps no instance lock; `omarchy-restart-shell` stops every instance with `quickshell kill` in a loop. | The runner holds the instance lock, and the shell draws only as the runner's child. | One shell per session is a VGS invariant ([overview.md](../architecture/overview.md) invariant 1), and every `vgsh` command addresses the one instance the lock file names. |
| The launcher relaunches a shell that exits with a non-zero status, up to five times a minute. | The runner exits with the shell's status and does not relaunch it. | `vgsh restart` does not supervise crashes ([runtime.md § Process](../architecture/runtime.md#process)); a relaunch loop is a separate decision. |
| No parent-death signal: a launcher killed with SIGKILL leaves the shell running. | `setpriv --pdeathsig TERM` stops the shell with its runner. | With no lock, a surviving shell breaks no invariant for Omarchy; for VGS it would be a guarded shell with the lock free. |

**Revisit When**: Quickshell gives QML a file lock; VGS adds crash supervision to the runner; or util-linux drops `setpriv --pdeathsig`.

**Verification**: `scripts/test-vgsh-run.sh` runs the runner against a stub `qs` and pins the lock file and `VGSH_RUNNER_PID`, the shell's descriptors, TERM and INT passed on, the repeated wait, the exit status, a free lock and a next start after a shell that left a process behind or crashed, and the parent-death signal, each with a control on a copy of `bin/vgsh`. `scripts/test-vgsh.sh` pins `run`, `pid` and `restart` against the same pid contract. `scripts/smoke/rows/start-order.sh` reads, in the nested sandbox, `vgsh restart` during a planted process that stands in for a download, and `vgsh run` after a SIGKILL to the shell, with a copy of the tree whose runner execs `qs` with the descriptor open as the control.

**References**: [runtime.md § Process](../architecture/runtime.md#process), [validation-smoke-harness.md](../architecture/validation-smoke-harness.md)
